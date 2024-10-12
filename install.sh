#!/bin/bash

# 更新系统并安装基本依赖
sudo apt update && sudo apt upgrade -y

# 安装必要工具
sudo apt install -y software-properties-common

# 添加Python 3.8 PPA并安装
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt update
sudo apt install -y python3.8 python3.8-dev python3.8-venv python3-pip

# 设置默认Python为3.8版本
sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.8 1
sudo update-alternatives --config python3

# 更新pip
python3 -m pip install --upgrade pip

# 安装MongoDB
sudo apt install -y mongodb
sudo systemctl start mongodb
sudo systemctl enable mongodb

# 安装Python虚拟环境和依赖
python3 -m venv price_tracker_env
source price_tracker_env/bin/activate
pip install requests pymongo flask beautifulsoup4 pandas lxml

# 创建项目结构
mkdir -p price_tracker/templates
touch price_tracker/scraper.py
touch price_tracker/app.py
touch price_tracker/templates/index.html
touch price_tracker/fetch_data.py

# 创建scraper.py文件，用于从Coles抓取商品数据并处理历史价格
cat <<EOL > price_tracker/scraper.py
import requests
import pandas as pd
from bs4 import BeautifulSoup
from pymongo import MongoClient
from datetime import datetime

client = MongoClient('localhost', 27017)
db = client['price_tracker_db']
coles_collection = db['coles']
history_collection = db['history']

# 从Coles抓取数据
def get_coles_data():
    url = 'https://shop.coles.com.au/a/a-national/everything/browse'
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3'
    }
    response = requests.get(url, headers=headers)
    soup = BeautifulSoup(response.content, 'html.parser')
    
    products = []
    for product in soup.find_all('div', class_='product'):
        name = product.find('h2', class_='product-name').text.strip()
        price = product.find('span', class_='product-price').text.strip().replace('$', '')
        image = product.find('img', class_='product-image')['src']
        products.append({'name': name, 'price': float(price), 'image': image})
    
    return products

# 存储商品数据及历史价格
def store_coles_data(products):
    for product in products:
        existing = coles_collection.find_one({'name': product['name']})
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

        # 更新或插入最新价格
        coles_collection.update_one(
            {'name': product['name']},
            {'$set': {'price': product['price'], 'image': product['image'], 'last_updated': now}},
            upsert=True
        )

        # 存储历史价格记录
        history_collection.update_one(
            {'name': product['name']},
            {'$push': {'price_history': {'price': product['price'], 'date': now}}},
            upsert=True
        )
EOL

# 创建Flask应用(app.py)
cat <<EOL > price_tracker/app.py
from flask import Flask, render_template
from pymongo import MongoClient
from scraper import get_coles_data, store_coles_data

app = Flask(__name__)

client = MongoClient('localhost', 27017)
db = client['price_tracker_db']

@app.route('/')
def index():
    coles_products = list(db['coles'].find())
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
    <table border="1">
        <thead>
            <tr>
                <th>商品</th>
                <th>图片</th>
                <th>价格</th>
                <th>最近更新</th>
            </tr>
        </thead>
        <tbody>
            {% for product in coles_products %}
            <tr>
                <td>{{ product['name'] }}</td>
                <td><img src="{{ product['image'] }}" alt="{{ product['name'] }}" width="100px"></td>
                <td>\${{ product['price'] }}</td>
                <td>{{ product['last_updated'] }}</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>
</body>
</html>
EOL

# 一键抓取Coles数据 (fetch_data.py)
cat <<EOL > price_tracker/fetch_data.py
from scraper import get_coles_data, store_coles_data

# 获取并存储Coles商品数据
coles_data = get_coles_data()
store_coles_data(coles_data)
EOL

# 创建定时任务，通过cron每小时运行抓取脚本
(crontab -l 2>/dev/null; echo "0 * * * * /path/to/your/python3 /path/to/price_tracker/fetch_data.py") | crontab -

echo "安装完成！"
echo "1. 使用虚拟环境：source price_tracker_env/bin/activate"
echo "2. 运行Flask应用：cd price_tracker && python app.py"
