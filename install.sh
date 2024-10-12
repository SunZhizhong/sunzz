#!/bin/bash

# 更新系统并升级软件包
sudo apt update && sudo apt upgrade -y

# 安装必要的依赖
sudo apt install -y build-essential libssl-dev libffi-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm libncurses5-dev libncursesw5-dev xz-utils tk-dev libgdbm-dev libc6-dev liblzma-dev python-openssl git

# 安装 Python 3.8
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt update
sudo apt install -y python3.8 python3.8-dev python3.8-venv

# 安装最新版本的 pip
curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
python3.8 get-pip.py

# 设置 Python 3.8 为默认 Python 版本
sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.8 1
sudo update-alternatives --install /usr/bin/pip3 pip3 /usr/local/bin/pip3 1

# 安装 MongoDB
sudo apt install -y mongodb
sudo systemctl start mongodb
sudo systemctl enable mongodb

# 安装 Python 依赖
pip3 install virtualenv
virtualenv price_tracker_env
source price_tracker_env/bin/activate
pip install requests pymongo flask beautifulsoup4 lxml pandas

# 创建项目结构
mkdir -p price_tracker/templates

# 创建scraper.py文件，用于抓取Coles商品数据并存储历史价格
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
    soup = BeautifulSoup(response.content, 'html.parser')
    products = soup.find_all('div', class_='product')
    
    product_list = []
    for product in products:
        name = product.find('h2', class_='product-name').text.strip()
        price = product.find('span', class_='product-price').text.strip().replace('$', '')
        image = product.find('img')['src']
        product_list.append({'name': name, 'price': float(price), 'image': image})

    return product_list

# 存储数据并记录历史价格
def store_data(products):
    for product in products:
        existing_product = coles_collection.find_one({'name': product['name']})
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

        # 更新最新价格
        coles_collection.update_one(
            {'name': product['name']},
            {'$set': {'price': product['price'], 'image': product['image'], 'last_updated': now}},
            upsert=True
        )

        # 记录历史价格
        history_collection.update_one(
            {'name': product['name']},
            {'$push': {'price_history': {'price': product['price'], 'date': now}}},
            upsert=True
        )

# 获取历史最低价
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

# 连接MongoDB
client = MongoClient('localhost', 27017)
db = client['price_tracker_db']

@app.route('/')
def index():
    products = list(db['coles'].find())
    for product in products:
        product['lowest_price'] = get_lowest_price(product['name'])
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
                <td>${{ product['price'] }}</td>
                <td>${{ product['lowest_price'] }}</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>
</body>
</html>
EOL

# 创建自动抓取商品数据的脚本 (fetch_data.py)
cat <<EOL > price_tracker/fetch_data.py
from scraper import get_coles_data, store_data

# 抓取Coles商品数据并存储
products = get_coles_data()
store_data(products)
EOL

# 配置定时任务，通过cron每小时运行抓取脚本
(crontab -l 2>/dev/null; echo "0 * * * * /path/to/your/python3 /path/to/price_tracker/fetch_data.py") | crontab -

echo "安装完成！"
echo "1. 使用虚拟环境：source price_tracker_env/bin/activate"
echo "2. 运行Flask应用：cd price_tracker && python app.py"
