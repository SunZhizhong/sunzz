#!/bin/bash

# 更新系统并安装依赖
sudo dnf update -y
sudo dnf install -y wget curl git gcc openssl-devel bzip2-devel libffi-devel zlib-devel make policycoreutils-python-utils

# 安装 Python 3.8
cd /usr/src
sudo wget https://www.python.org/ftp/python/3.8.0/Python-3.8.0.tgz
sudo tar xzf Python-3.8.0.tgz
cd Python-3.8.0
sudo ./configure --enable-optimizations
sudo make altinstall

# 检查 Python 和 pip 版本
python3.8 --version
pip3.8 --version

# 安装或升级 pip
curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
sudo python3.8 get-pip.py

# 解决 PIP3 安装问题
if [ ! -L /usr/bin/pip3 ]; then
  sudo ln -s /usr/local/bin/pip3.8 /usr/bin/pip3
fi
pip3 install --upgrade pip==24.2

# 安装 MongoDB 6.0
sudo tee -a /etc/yum.repos.d/mongodb-org-6.0.repo <<EOF
[mongodb-org-6.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/6.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-6.0.asc
EOF

sudo dnf install -y mongodb-org
sudo systemctl start mongod
sudo systemctl enable mongod

# 检查 MongoDB 状态并升级
mongod --version

# 确保 SELinux 不会拦截 MongoDB
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# 生成本地 SELinux 策略以允许 Mongod 访问被阻止的目录
sudo grep mongod /var/log/audit/audit.log | audit2allow -M mongod_local
sudo semodule -i mongod_local.pp

# 确保 MongoDB 的端口未被防火墙阻止
sudo firewall-cmd --permanent --add-port=27017/tcp
sudo firewall-cmd --reload

# 确保 MongoDB 对 /tmp 具有写权限
sudo chmod -R 1777 /tmp

# 删除所有 MongoDB 用户
mongo <<EOF
use admin
db.dropAllUsers()
db.createUser({
  user: "flask_user",
  pwd: "flask_password",
  roles: [{ role: "userAdminAnyDatabase", db: "admin" }, { role: "readWriteAnyDatabase", db: "admin" }]
})
EOF

# 安装 Python 虚拟环境和依赖
pip3 install virtualenv
virtualenv price_tracker_env
source price_tracker_env/bin/activate
pip install requests pymongo flask beautifulsoup4

# 克隆 Coles-scraper 仓库
if [ -d "coles-scraper" ]; then
  sudo rm -rf coles-scraper
fi
git clone https://github.com/adambadge/coles-scraper.git

# 创建 scraper.py 文件，用于从 Coles 抓取商品数据
cat <<EOL > scraper.py
import requests
from bs4 import BeautifulSoup
from pymongo import MongoClient
from datetime import datetime

client = MongoClient('mongodb://flask_user:flask_password@localhost:27017/admin?authSource=admin')
db = client['price_tracker_db']
coles_collection = db['coles']
history_collection = db['history']

def get_coles_data():
    url = 'https://shop.coles.com.au/a/a-national/everything/browse'
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3'
    }
    response = requests.get(url, headers=headers)
    if response.status_code == 200:
        soup = BeautifulSoup(response.content, 'html.parser')
        products = []
        for product in soup.find_all('div', class_='product'):  # 修改选择器以匹配正确的产品容器
            name = product.find('a', class_='product-title').get_text(strip=True)
            price = product.find('span', class_='dollar-value').get_text(strip=True)
            image_tag = product.find('img', class_='product-image')
            image = image_tag['src'] if image_tag else ''
            products.append({'name': name, 'price': price, 'image': image})
        return products
    else:
        print(f"Error fetching Coles data: {response.status_code}")
        return []

def store_data(products):
    for product in products:
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        coles_collection.update_one(
            {'name': product['name']},
            {'$set': {'price': product['price'], 'image': product['image'], 'last_updated': now}},
            upsert=True
        )
        history_collection.update_one(
            {'name': product['name']},
            {'$push': {'price_history': {'price': product['price'], 'date': now}}},
            upsert=True
        )

products = get_coles_data()
store_data(products)
EOL

# 创建 Flask 应用 (app.py)
cat <<EOL > app.py
from flask import Flask, render_template
from pymongo import MongoClient

app = Flask(__name__)
client = MongoClient('mongodb://flask_user:flask_password@localhost:27017/admin?authSource=admin')
db = client['price_tracker_db']

@app.route('/')
def index():
    coles_products = list(db['coles'].find())
    for product in coles_products:
        history = db['history'].find_one({'name': product['name']})
        if history and 'price_history' in history:
            product['lowest_price'] = min([h['price'] for h in history['price_history']])
        else:
            product['lowest_price'] = product['price']
    return render_template('index.html', products=coles_products)

if __name__ == '__main__':
    app.run(debug=True)
EOL

# 创建 HTML 模板 (index.html)
mkdir -p templates
cat <<EOL > templates/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>商品价格列表</title>
</head>
<body>
    <h1>Coles 商品价格列表</h1>
    <table>
        <thead>
            <tr>
                <th>商品</th>
                <th>当前价格</th>
                <th>历史最低价</th>
            </tr>
        </thead>
        <tbody>
            {% for product in products %}
            <tr>
                <td><img src="{{ product['image'] }}" alt="{{ product['name'] }}" width="100px">{{ product['name'] }}</td>
                <td>{{ product['price'] }}</td>
                <td>{{ product['lowest_price'] }}</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>
</body>
</html>
EOL

# 运行 Flask 应用
python3.8 app.py &

else
    echo "Flask 应用未能启动"
fi

echo "安装完成！请访问 http://localhost:5000 查看商品信息。"
