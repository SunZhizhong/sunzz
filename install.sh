#!/bin/bash

# 更新系统
sudo apt update && sudo apt upgrade -y

# 安装依赖库
sudo apt install -y build-essential zlib1g-dev libssl-dev libncurses5-dev libffi-dev libsqlite3-dev libreadline-dev libbz2-dev wget git

# 安装 Python 3.8
sudo apt install -y python3.8 python3.8-venv python3.8-dev

# 设置 Python 3.8 为默认版本
sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.8 1
sudo update-alternatives --config python3

# 安装最新版本的 pip
curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
python3 get-pip.py
pip install --upgrade pip==24.2.2

# 安装 MongoDB
sudo apt install -y mongodb
sudo systemctl start mongodb
sudo systemctl enable mongodb

# 安装 Python 虚拟环境
pip install virtualenv
virtualenv price_tracker_env
source price_tracker_env/bin/activate

# 安装Python依赖
pip install requests pymongo flask beautifulsoup4 pandas lxml

# 创建项目目录结构
mkdir -p price_tracker/templates
touch price_tracker/scraper.py price_tracker/app.py price_tracker/fetch_data.py price_tracker/templates/index.html

# 创建scraper.py文件，用于从Coles抓取商品信息
cat <<EOL > price_tracker/scraper.py
import requests
import pandas as pd
from bs4 import BeautifulSoup
from pymongo import MongoClient
from datetime import datetime

# 连接MongoDB
client = MongoClient('localhost', 27017)
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
        products = soup.find_all('div', class_='product')
        product_list = []
        for product in products:
            try:
                name = product.find('h2', class_='product-name').text.strip()
                price = product.find('span', class_='product-price').text.strip().replace("\$", "")
                image = product.find('img')['src']
                product_list.append({'name': name, 'price': float(price), 'image': image})
            except Exception as e:
                print(f"Error processing product: {e}")
        return product_list
    else:
        print(f"Error fetching Coles data: {response.status_code}")
        return []

# 存储商品数据并处理历史价格
def store_coles_data(products):
    for product in products:
        existing = coles_collection.find_one({'name': product['name']})
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        
        # 更新商品最新价格
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
EOL

# 创建app.py文件，用于启动Flask应用并展示商品信息
cat <<EOL > price_tracker/app.py
from flask import Flask, render_template
from pymongo import MongoClient

app = Flask(__name__)

client = MongoClient('localhost', 27017)
db = client['price_tracker_db']

@app.route('/')
def index():
    coles_products = list(db['coles'].find())
    for product in coles_products:
        product['lowest_price'] = get_lowest_price(product['name'])
    return render_template('index.html', products=coles_products)

if __name__ == '__main__':
    app.run(debug=True)
EOL

# 创建fetch_data.py文件，用于抓取Coles商品信息并存储
cat <<EOL > price_tracker/fetch_data.py
from scraper import get_coles_data, store_coles_data

# 抓取并存储Coles商品数据
products = get_coles_data()
store_coles_data(products)
EOL

# 创建HTML模板，用于显示商品信息
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
                <th>当前价格</th>
                <th>历史最低价</th>
                <th>图片</th>
            </tr>
        </thead>
        <tbody>
            {% for product in products %}
            <tr>
                <td>{{ product['name'] }}</td>
                <td>{{ product['price'] }}</td>
                <td>{{ product['lowest_price'] }}</td>
                <td><img src="{{ product['image'] }}" alt="{{ product['name'] }}" width="100px"></td>
            </tr>
            {% endfor %}
        </tbody>
    </table>
</body>
</html>
EOL

# 创建定时任务，通过cron每小时运行抓取脚本
(crontab -l 2>/dev/null; echo "0 * * * * /path/to/your/python3 /path/to/price_tracker/fetch_data.py") | crontab -

echo "安装完成！"
echo "1. 使用虚拟环境：source price_tracker_env/bin/activate"
echo "2. 运行Flask应用：cd price_tracker && python app.py"
