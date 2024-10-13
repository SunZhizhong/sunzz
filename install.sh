#!/bin/bash

# 一键安装脚本用于批量获取澳洲各个网站生活用品和食品价格，适用于CentOS 7

# 安装必要工具和插件
sudo yum install -y git make checkpolicy policycoreutils selinux-policy-devel wget gcc openssl-devel bzip2-devel libffi-devel zlib-devel
if [ $? -ne 0 ]; then
    echo "[错误] 无法安装必要工具和插件，请检查网络连接或软件源设置。"
    exit 1
fi

# 安装 Python 3.8 和 pip
PYTHON_VERSION="3.8.16"
cd /usr/src
sudo wget -O Python-$PYTHON_VERSION.tgz https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz
if [ $? -ne 0 ]; then
    echo "[错误] 无法下载 Python 源代码。"
    exit 1
fi
sudo tar --overwrite -xzf Python-$PYTHON_VERSION.tgz
cd Python-$PYTHON_VERSION
sudo ./configure --enable-optimizations
sudo make altinstall
if [ $? -ne 0 ]; then
    echo "[错误] 无法编译安装 Python。"
    exit 1
fi
sudo ln -s /usr/local/bin/python3.8 /usr/bin/python3
sudo ln -s /usr/local/bin/pip3.8 /usr/bin/pip3

# 安装 MongoDB 4.0
cat <<EOF | sudo tee /etc/yum.repos.d/mongodb-org-4.0.repo
[mongodb-org-4.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/7Server/mongodb-org/4.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-4.0.asc
EOF

sudo yum install -y mongodb-org
if [ $? -ne 0 ]; then
    echo "[错误] 无法安装 MongoDB。"
    exit 1
fi

# 配置 MongoDB，确保其用户对 /tmp 具有写权限，且端口未被防火墙阻止
sudo setfacl -m u:mongodb:rwx /tmp
sudo systemctl start mongod
sudo systemctl enable mongod
sudo firewall-cmd --zone=public --add-port=27017/tcp --permanent
sudo firewall-cmd --reload
if [ $? -ne 0 ]; then
    echo "[错误] 防火墙配置失败。"
    exit 1
fi

# 创建 MongoDB 用户并赋予读写权限
mongo <<EOF
use admin
db.createUser({
  user: "admin",
  pwd: "password",
  roles: [ { role: "userAdminAnyDatabase", db: "admin" } ]
})
use coles
// 创建数据库用户
db.createUser({
  user: "coles_user",
  pwd: "coles_password",
  roles: [ { role: "readWrite", db: "coles" } ]
})
EOF

# 安装 MongoDB 的 SELinux 策略
cd /opt
git clone https://github.com/mongodb/mongodb-selinux
cd mongodb-selinux
make
sudo make install -B
if [ $? -ne 0 ]; then
    echo "[错误] 无法安装 MongoDB 的 SELinux 策略。"
    exit 1
fi

# 安装 Python 的 MongoDB 驱动程序 (pymongo)
pip3 install pymongo
if [ $? -ne 0 ]; then
    echo "[错误] 无法安装 pymongo。"
    exit 1
fi

# 获取 coles.ipynb 文件
wget https://raw.githubusercontent.com/adambadge/coles-scraper/master/coles.ipynb -O coles.ipynb
if [ $? -ne 0 ]; then
    echo "[错误] 无法下载 coles.ipynb 文件。"
    exit 1
fi

# 使用 nbconvert 将 .ipynb 转换为 Python 脚本并执行
pip3 install nbconvert
if [ $? -ne 0 ]; then
    echo "[错误] 无法安装 nbconvert。"
    exit 1
fi
jupyter nbconvert --to script coles.ipynb
if [ $? -ne 0 ]; then
    echo "[错误] 无法将 coles.ipynb 转换为 Python 脚本。"
    exit 1
fi
python3 coles.py
if [ $? -ne 0 ]; then
    echo "[错误] 运行 Coles 抓取脚本失败。"
    exit 1
fi

# 前端 HTML 显示商品的图片，名称，实时价格，当前打折情况，历史最低价
# 创建一个简单的 Flask 应用程序以实现前后端整合
pip3 install Flask
if [ $? -ne 0 ]; then
    echo "[错误] 无法安装 Flask。"
    exit 1
fi

# 创建 Flask 应用程序目录并编写代码
mkdir -p /opt/coles_flask_app
cd /opt/coles_flask_app

cat <<EOF > app.py
from flask import Flask, render_template
import pymongo

app = Flask(__name__)

# 连接到 MongoDB 数据库
client = pymongo.MongoClient("mongodb://localhost:27017/")
db = client["coles"]
collection = db["products"]

@app.route('/')
def index():
    # 从数据库中获取商品信息
    products = collection.find()
    return render_template('index.html', products=products)

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=5000)
EOF

# 创建 HTML 模板目录并编写模板文件
mkdir -p templates

cat <<EOF > templates/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Coles Products</title>
</head>
<body>
    <h1>Coles Products</h1>
    <table border="1">
        <tr>
            <th>图片</th>
            <th>名称</th>
            <th>实时价格</th>
            <th>当前打折情况</th>
            <th>历史最低价</th>
        </tr>
        {% for product in products %}
        <tr>
            <td><img src="{{ product['image_url'] }}" alt="{{ product['name'] }}" width="100"></td>
            <td>{{ product['name'] }}</td>
            <td>{{ product['current_price'] }}</td>
            <td>{{ product['discount'] }}</td>
            <td>{{ product['historical_low'] }}</td>
        </tr>
        {% endfor %}
    </table>
</body>
</html>
EOF

# 启动 Flask 应用程序
python3 app.py &
if [ $? -ne 0 ]; then
    echo "[错误] 无法启动 Flask 应用程序。"
    exit 1
fi

# 完成
echo "[完成] 所有安装步骤均已成功完成，请访问您的网站以查看商品信息。"
