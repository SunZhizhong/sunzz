#!/bin/bash

# 更新系统并安装必需的依赖
sudo yum update -y
sudo yum groupinstall -y "Development Tools"
sudo yum install -y gcc openssl-devel bzip2-devel libffi-devel zlib-devel wget

# 安装 Python 3.8
cd /usr/src
sudo wget https://www.python.org/ftp/python/3.8.12/Python-3.8.12.tgz
sudo tar xzf Python-3.8.12.tgz
cd Python-3.8.12
sudo ./configure --enable-optimizations
sudo make altinstall

# 确认安装 Python 3.8 和 pip
python3.8 --version
sudo python3.8 -m ensurepip --upgrade
sudo python3.8 -m pip install --upgrade pip==24.2.0

# 安装 MongoDB
sudo tee -a /etc/yum.repos.d/mongodb-org-4.4.repo <<EOL
[mongodb-org-4.4]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/7/mongodb-org/4.4/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-4.4.asc
EOL

sudo yum install -y mongodb-org
sudo systemctl start mongod
sudo systemctl enable mongod

# 安装Python虚拟环境和依赖
sudo python3.8 -m pip install virtualenv
virtualenv price_tracker_env
source price_tracker_env/bin/activate
pip install requests pandas beautifulsoup4 flask pymongo

# 创建项目结构
mkdir -p price_tracker/templates

# 创建scraper.py文件，包含抓取Coles商品数据的逻辑并存储历史价格
cat <<EOL > price_tracker/scraper.py
import requests
from bs4 import BeautifulSoup
from pymongo import MongoClient
from datetime import datetime
import pandas as pd

client = MongoClient('localhost', 27017)
db = client['price_tracker_db']
coles_collection = db['coles']
history_collection = db['history']

# 获取Coles商品数据
def get_coles_data():
    url = 'https://shop.coles.com.au/a/a-national/everything/browse'
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3'
    }
    response = requests.get(url, headers=headers)
    soup = BeautifulSoup(response.content, 'html.parser')
    products = soup.find_all('div', class_='product')

    product_list = []
    for product in products:
        name = product.find('h2', class_='product-name').text.strip()
        price = product.find('span', class_='product-price').text.strip()
        image = product.find('img')['src'] if product.find('img') else ''
        product_list.append({'name': name, 'price': price, 'image': image})
    
    return product_list

# 存储商品数据并更新历史价格
def store_coles_data(products):
    now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    for product in products:
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

# 获取商品历史最低价格
def get_lowest_price(product_name):
    history = history_collection.find_one({'name': product_name})
    if history and 'price_history' in history:
        lowest = min(history['price_history'], key=lambda x: x['price'])
        return lowest['price']
    return None

EOL

# 创建Flask应用 (app.py)
cat <<EOL > price_tracker/app.py
from flask import Flask, render_template
from pymongo import MongoClient
from scraper import get_lowest_price

app = Flask(__name__)

client = MongoClient('localhost', 27017)
db = client['price_tracker_db']

@app.route('/')
def index():
    coles_products = list(db['coles'].find())
    for product in coles_products:
        product['lowest_price'] = get_lowest_price(product['name'])
    return render_template('index.html', coles_products=coles_products)

if __name__ == '__main__':
    app.run(debug=True)
EOL

# 创建HTML模板 (index.html)
cat <<EOL > price_tracker/templates/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Coles 商品价格列表</title>
</head>
<body>
    <h1>Coles 商品价格列表</h1>
    <table>
        <thead>
            <tr>
                <th>商品</th>
                <th>实时价格</th>
                <th>历史最低价</th>
            </tr>
        </thead>
        <tbody>
            {% for product in coles_products %}
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

# 创建数据抓取脚本 (fetch_data.py)
cat <<EOL > price_tracker/fetch_data.py
from scraper import get_coles_data, store_coles_data

# 抓取并存储Coles商品数据
coles_data = get_coles_data()
store_coles_data(coles_data)
EOL

# 创建定时任务，每小时抓取一次Coles商品数据
(crontab -l 2>/dev/null; echo "0 * * * * /path/to/your/python3.8 /path/to/price_tracker/fetch_data.py") | crontab -

echo "安装完成！"
echo "1. 激活虚拟环境: source price_tracker_env/bin/activate"
echo "2. 运行Flask应用: cd price_tracker && python app.py"
