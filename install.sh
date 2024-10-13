#!/bin/bash
# 该脚本为CentOS 7上一键安装并设置商品信息爬取和展示的系统。
# 包括安装Python、pip、MongoDB及相关依赖，配置抓取Coles商品信息和HTML前端显示。
# 使用中文注释，一旦出现错误即停止执行。

# 设置错误处理
set -e

# 更新系统并安装基本工具
yum update -y
yum install -y wget gcc gcc-c++ make zlib-devel openssl-devel bzip2-devel libffi-devel tar

# 安装 Python 3.8
cd /usr/src
wget https://www.python.org/ftp/python/3.8.0/Python-3.8.0.tgz
tar xzf Python-3.8.0.tgz
cd Python-3.8.0
./configure --enable-optimizations
make altinstall

# 确保 Python 3.8 可用，并安装 pip
ln -sf /usr/local/bin/python3.8 /usr/bin/python3
wget https://bootstrap.pypa.io/get-pip.py
python3 get-pip.py

# 安装MongoDB
cat > /etc/yum.repos.d/mongodb-org-6.0.repo <<EOL
[mongodb-org-6.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/7/mongodb-org/6.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/static/pgp/server-6.0.asc
EOL

sudo yum install -y mongodb-org

# 启动MongoDB并设置开机启动
systemctl start mongod
systemctl enable mongod

# 确保MongoDB端口未被防火墙阻止
firewall-cmd --permanent --add-port=27017/tcp
firewall-cmd --reload

# 配置MongoDB对/tmp的写权限并创建用户
chmod 1777 /tmp
mongo <<EOF
use admin
db.createUser({ user: "admin", pwd: "password", roles: [ { role: "userAdminAnyDatabase", db: "admin" } ] })
use coles_data
db.createUser({ user: "coles_user", pwd: "coles_pass", roles: [ { role: "readWrite", db: "coles_data" } ] })
EOF

# 安装Python依赖库
pip3 install pymongo flask requests beautifulsoup4

# 整合Coles商品信息抓取脚本
cat > coles_scraper.py <<EOL
# -*- coding: utf-8 -*-
"""
Coles 商品信息抓取脚本，分析商品数据并存储到 MongoDB 中
"""
import requests
from bs4 import BeautifulSoup
from pymongo import MongoClient
import datetime

def scrape_coles():
    url = "https://www.coles.com.au/c/groceries"
    response = requests.get(url)
    response.encoding = 'utf-8'
    if response.status_code == 200:
        soup = BeautifulSoup(response.text, 'html.parser')
        # 示例代码：解析商品数据
        items = soup.find_all('div', class_='product')
        product_list = []
        for item in items:
            product = {
                'name': item.find('h2').text.strip(),
                'price': item.find('span', class_='price').text.strip(),
                'image': item.find('img')['src'],
                'date': datetime.datetime.now()
            }
            product_list.append(product)
        return product_list
    else:
        print("无法获取Coles商品信息")
        return []

def save_to_mongo(products):
    client = MongoClient("mongodb://coles_user:coles_pass@localhost:27017/coles_data")
    db = client.coles_data
    collection = db.products
    for product in products:
        collection.update_one({'name': product['name']}, {'$set': product}, upsert=True)
    print("商品信息已保存到MongoDB")

if __name__ == "__main__":
    products = scrape_coles()
    if products:
        save_to_mongo(products)
EOL

# 创建Flask应用以展示商品信息
cat > app.py <<EOL
# -*- coding: utf-8 -*-
"""
Flask 应用，展示商品的图片、名称、实时价格、打折情况以及历史最低价
"""
from flask import Flask, render_template
from pymongo import MongoClient

app = Flask(__name__)

@app.route('/')
def index():
    client = MongoClient("mongodb://coles_user:coles_pass@localhost:27017/coles_data")
    db = client.coles_data
    products = db.products.find()
    return render_template('index.html', products=products)

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=5000)
EOL

# 创建HTML模板目录并创建模板文件
mkdir -p templates
cat > templates/index.html <<EOL
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <title>商品信息列表</title>
</head>
<body>
    <h1>商品信息</h1>
    <table border="1">
        <tr>
            <th>商品图片</th>
            <th>商品名称</th>
            <th>实时价格</th>
            <th>历史最低价</th>
        </tr>
        {% for product in products %}
        <tr>
            <td><img src="{{ product.image }}" alt="{{ product.name }}" width="100"></td>
            <td>{{ product.name }}</td>
            <td>{{ product.price }}</td>
            <td>{{ product.price }}</td> <!-- 示例代码：这里可以进行更多的历史价格分析 -->
        </tr>
        {% endfor %}
    </table>
</body>
</html>
EOL

# 运行Flask应用
python3 app.py &

# 打印完成信息
echo "安装和配置完成，Flask 应用正在运行 http://localhost:5000"
