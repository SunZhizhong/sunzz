#!/bin/bash
# Coles Scraper Installation Script - CentOS 7
# 用于在 CentOS 7 上自动安装所需的工具和插件，并配置环境
# 确保脚本在任何步骤中遇到错误时立即停止
set -e

# 更新系统
sudo yum update -y

# 安装必备工具和依赖
sudo yum install -y gcc openssl-devel bzip2-devel libffi-devel wget vim

# 编译安装 Python 3.8
cd /usr/src
wget https://www.python.org/ftp/python/3.8.0/Python-3.8.0.tgz
tar xzf Python-3.8.0.tgz
cd Python-3.8.0
./configure --enable-optimizations
make altinstall

# 检查 Python 和 pip 的版本
python3.8 --version
pip3.8 --version

# 安装 pip
curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
python3.8 get-pip.py

# 安装 MongoDB
sudo tee -a /etc/yum.repos.d/mongodb-org-6.0.repo <<EOF
[mongodb-org-6.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/7/mongodb-org/6.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-6.0.asc
EOF

sudo yum install -y mongodb-org

# 启动并配置 MongoDB
sudo systemctl start mongod
sudo systemctl enable mongod

# 检查 MongoDB 是否正在运行
if ! pgrep -x "mongod" > /dev/null
then
    echo "MongoDB 未能启动，请检查安装过程。"
    exit 1
fi

# 配置 MongoDB 以允许对 /tmp 的写权限
sudo chmod 1777 /tmp

# 检查防火墙配置，确保 MongoDB 端口未被阻止
sudo firewall-cmd --zone=public --add-port=27017/tcp --permanent
sudo firewall-cmd --reload

# 设置 MongoDB 路径
export PATH=$PATH:/usr/bin

# 创建 MongoDB 用户并授予读写权限
sudo /bin/bash -c 'echo "use admin
db.createUser({
  user: \"myUserAdmin\",
  pwd: \"abc123\",
  roles: [ { role: \"userAdminAnyDatabase\", db: \"admin\" }, \"readWriteAnyDatabase\" ]
})" | /usr/bin/mongo'

# 安装 Python 所需的库
pip3.8 install pymongo flask requests beautifulsoup4

# 克隆 Coles Scraper 并集成到系统
cd /opt
sudo git clone https://github.com/adambadge/coles-scraper.git
cd coles-scraper

# 编辑代码以解决 Non-ASCII 问题
# 将代码中的文件打开，确保所有文件以 utf-8 编码处理
sudo vim coles.ipynb

# 创建 Flask 应用，显示商品信息
cat <<EOL > /opt/coles-scraper/app.py
from flask import Flask, render_template
import pymongo

app = Flask(__name__)

@app.route('/')
def home():
    client = pymongo.MongoClient("mongodb://myUserAdmin:abc123@localhost:27017/")
    db = client["coles_database"]
    products = db["products"].find()
    return render_template('index.html', products=products)

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=5000)
EOL

# 创建 HTML 模板以显示商品信息
mkdir -p /opt/coles-scraper/templates
cat <<EOL > /opt/coles-scraper/templates/index.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>Coles 商品信息</title>
</head>
<body>
    <h1>商品列表</h1>
    <ul>
        {% for product in products %}
        <li>
            <img src="{{ product['image'] }}" alt="{{ product['name'] }}">
            <p>名称: {{ product['name'] }}</p>
            <p>价格: {{ product['price'] }}</p>
            <p>打折情况: {{ product['discount'] }}</p>
            <p>历史最低价: {{ product['lowest_price'] }}</p>
        </li>
        {% endfor %}
    </ul>
</body>
</html>
EOL

# 启动 Flask 应用
cd /opt/coles-scraper
python3.8 app.py &

# 提示用户安装完成
echo "安装完成，Flask 应用已启动，访问 http://localhost:5000 查看商品信息。"
