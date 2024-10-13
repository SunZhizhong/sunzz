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

# 克隆并安装 Coles 商品信息抓取代码
git clone --recurse-submodules https://github.com/adambadge/coles-scraper.git
cd coles-scraper
pip3 install --default-timeout=100 -r requirements.txt
if [ $? -ne 0 ]; then
    echo "[错误] 无法安装 Coles 抓取代码的依赖，请检查网络连接或手动安装依赖。"
    exit 1
fi

# 运行商品抓取脚本并存储商品信息到 MongoDB
python3 coles.ipynb
if [ $? -ne 0 ]; then
    echo "[错误] 运行 Coles 抓取脚本失败。"
    exit 1
fi

# 前端 HTML 显示商品的图片，名称，实时价格，当前打折情况，历史最低价
# 此处省略详细 HTML 代码，但请确保通过 Flask 或其他 Web 框架进行前后端整合

# 启动 Flask 应用程序
cd /opt/your_flask_app_directory
pip3 install -r requirements.txt
if [ $? -ne 0 ]; then
    echo "[错误] 无法安装 Flask 应用程序的依赖。"
    exit 1
fi
python3 app.py
if [ $? -ne 0 ]; then
    echo "[错误] 无法启动 Flask 应用程序。"
    exit 1
fi

# 完成
echo "[完成] 所有安装步骤均已成功完成，请访问您的网站以查看商品信息。"
