#!/bin/bash

# 更新系统并安装依赖
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3 python3-pip mongodb git

# 启动并启用MongoDB
sudo systemctl start mongodb
sudo systemctl enable mongodb

# 安装Python虚拟环境和依赖
pip3 install virtualenv
virtualenv price_tracker_env
source price_tracker_env/bin/activate
pip install requests pymongo flask pandas beautifulsoup4 lxml

# 创建项目目录
mkdir -p price_tracker/templates

# 创建scraper.py文件，用于抓取Coles商品信息并存储历史价格
cat <<EOL > price_tracker/scraper.py
import requests
from bs4 import BeautifulSoup
import pandas as pd
from pymongo import MongoClient
from datetime import datetime

# 连接MongoDB
client = MongoClient('localhost', 27017)
db = client['price_tracker_db']
coles_collection = db['coles']
history_collection = db['history']

# 获取Coles数据
def get_coles_data():
    url = 'https://shop.coles.com.au/a/a-national/everything/browse'
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3'
    }
    response = requests.get(url, headers=headers)
    soup = BeautifulSoup(response.content, 'lxml')
    products = soup.find_all('div', class_='product')

    product_list = []
    for product in products:
        try:
            name = product.find('h2', class_='product-name').text.strip()
            price = product.find('span', class_='product-price').text.strip()
            image = product.find('img')['src'] if product.find('img') else ''
            product_list.append({'name': name, 'price': float(price.replace('$', '')), 'image': image})
        except Exception as e:
            print(f"Error parsing product: {e}")
    
    return product_list

# 存储商品数据和历史价格
def store_data(products):
    for product in products:
        existing = coles_collection.find_one({'name': product['name']})
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

        # 更新最新价格信息
        coles_collection.update_one(
            {'name': product['name']},
            {'$set': {'price': product['price'], 'image': product['image'], 'last_updated': now}},
            upsert=True
        )

        # 存储历史价格
        history_collection.update_one(
            {'name': product['name']},
            {'$push': {'price_history': {'price': product['price'], 'date': now}}},
            upsert=True
        )

def get_lowest_price(product_name):
    history = history_collection.find_one({'name': product_name})
    if history and 'price_history' in history:
        lowest = min(history['price_history'], key=lambda x: x['price'])
        return lowest['price']
    return None

def get_products_with_lowest_prices():
    products = list(coles_collection.find())
    for product in products:
        product['lowest_price'] = get_lowest_price(product['name'])
    return products

EOL

# 创建Flask应用 (app.py)
cat <<EOL > price_tracker/app.py
from flask import Flask, render_template
from pymongo import MongoClient
from scraper import get_products_with_lowest_prices

app = Flask(__name__)

client = MongoClient('localhost', 27017)
db = client['price_tracker_db']

@app.route('/')
def index():
    products = get_products_with_lowest_prices()
    return render_template('index.html', products=products)

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
                <th>当前价格</th>
                <th>历史最低价</th>
                <th>更新时间</th>
            </tr>
        </thead>
        <tbody>
            {% for product in products %}
            <tr>
                <td><img src="{{ product['image'] }}" alt="{{ product['name'] }}" width="100px">{{ product['name'] }}</td>
                <td>\${{ product['price'] }}</td>
                <td>\${{ product['lowest_price'] }}</td>
                <td>{{ product['last_updated'] }}</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>
</body>
</html>
EOL

# 一键抓取商品数据 (fetch_data.py)
cat <<EOL > price_tracker/fetch_data.py
from scraper import get_coles_data, store_data

# 抓取Coles商品数据并存储
coles_data = get_coles_data()
store_data(coles_data)
EOL

# 创建定时任务，每小时运行一次抓取脚本
(crontab -l 2>/dev/null; echo "0 * * * * /path/to/your/python3 /path/to/price_tracker/fetch_data.py") | crontab -

echo "安装完成！"
echo "1. 使用虚拟环境：source price_tracker_env/bin/activate"
echo "2. 运行Flask应用：cd price_tracker && python app.py"
