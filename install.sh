#!/bin/bash

# 更新系统并安装必要的工具
sudo dnf update -y
sudo dnf install -y python3 python3-pip git gcc openssl-devel bzip2-devel libffi-devel wget make

# 安装最新版本的 Python（假设系统没有更新的 Python 版本）
cd /usr/src
sudo wget https://www.python.org/ftp/python/3.9.9/Python-3.9.9.tgz
sudo tar xzf Python-3.9.9.tgz
cd Python-3.9.9
sudo ./configure --enable-optimizations
sudo make altinstall
sudo ln -s /usr/local/bin/python3.9 /usr/bin/python3
sudo ln -s /usr/local/bin/pip3.9 /usr/bin/pip3

# 验证 Python 和 pip 版本
python3 --version
pip3 --version

# 创建虚拟环境并安装必要的依赖
pip3 install virtualenv
virtualenv price_tracker_env
source price_tracker_env/bin/activate
pip install requests beautifulsoup4 pandas pymongo flask

# 启动并安装 MongoDB
sudo tee /etc/yum.repos.d/mongodb-org-5.0.repo <<EOF
[mongodb-org-5.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/5.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-5.0.asc
EOF

sudo dnf install -y mongodb-org
sudo systemctl start mongod
sudo systemctl enable mongod

# 克隆包含Coles抓取代码的仓库并整合
git clone https://github.com/adambadge/coles-scraper.git

# 创建项目目录并设置文件结构
mkdir -p price_tracker/templates

# 创建scraper.py文件，处理抓取Coles商品信息并存储到MongoDB
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
        product_list.append({'name': name, 'price': price})
    
    return product_list

def store_coles_data(products):
    for product in products:
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        coles_collection.update_one(
            {'name': product['name']},
            {'$set': {'price': product['price'], 'last_updated': now}},
            upsert=True
        )
        history_collection.update_one(
            {'name': product['name']},
            {'$push': {'price_history': {'price': product['price'], 'date': now}}},
            upsert=True
        )

def get_lowest_price(product_name):
    history = history_collection.find_one({'name': product_name})
    if history and 'price_history' in history:
        lowest = min(history['price_history'], key=lambda x: float(x['price']))
        return lowest['price']
    return None
EOL

# 创建Flask应用 (app.py)
cat <<EOL > price_tracker/app.py
from flask import Flask, render_template
from pymongo import MongoClient
from scraper import get_coles_data, store_coles_data, get_lowest_price

app = Flask(__name__)

client = MongoClient('localhost', 27017)
db = client['price_tracker_db']

@app.route('/')
def index():
    coles_products = list(db['coles'].find())

    # 为每个商品获取历史最低价格
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
    <ul>
        {% if coles_products %}
            {% for product in coles_products %}
            <li>
                <p>{{ product['name'] }} - ${{ product['price'] }} (历史最低价: ${{ product['lowest_price'] }})</p>
            </li>
            {% endfor %}
        {% else %}
            <p>没有找到Coles商品数据</p>
        {% endif %}
    </ul>
</body>
</html>
EOL

# 创建数据抓取脚本 (fetch_data.py)
cat <<EOL > price_tracker/fetch_data.py
from scraper import get_coles_data, store_coles_data

coles_data = get_coles_data()
store_coles_data(coles_data)
EOL

# 为抓取数据设置定时任务，每小时运行一次数据抓取脚本
(crontab -l 2>/dev/null; echo "0 * * * * /path/to/your/python3 /path/to/price_tracker/fetch_data.py") | crontab -

# 安装完成提示
echo "安装完成！"
echo "1. 启动虚拟环境：source price_tracker_env/bin/activate"
echo "2. 运行Flask应用：cd price_tracker && python app.py"
