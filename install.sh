#!/bin/bash

# 確保腳本在出錯時停止
set -e

# 安裝所有必備工具插件
sudo yum update -y
sudo yum install -y git wget make checkpolicy policycoreutils selinux-policy-devel gcc openssl-devel bzip2-devel libffi-devel zlib-devel readline-devel sqlite-devel

# 編譯安裝指定版本的 Python 和 pip
PYTHON_VERSION=3.8.16
cd /usr/src
wget https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz
tar xzf Python-$PYTHON_VERSION.tgz
cd Python-$PYTHON_VERSION
./configure --enable-optimizations
make altinstall

# 創建 Python 和 pip 的軟連接
ln -sf /usr/local/bin/python3.8 /usr/bin/python3
ln -sf /usr/local/bin/pip3.8 /usr/bin/pip3

# 安裝 MongoDB 4.0
echo "[mongodb-org-4.0]" | sudo tee -a /etc/yum.repos.d/mongodb-org-4.0.repo
echo "name=MongoDB Repository" | sudo tee -a /etc/yum.repos.d/mongodb-org-4.0.repo
echo "baseurl=https://repo.mongodb.org/yum/redhat/$releasever/mongodb-org/4.0/x86_64/" | sudo tee -a /etc/yum.repos.d/mongodb-org-4.0.repo
echo "gpgcheck=1" | sudo tee -a /etc/yum.repos.d/mongodb-org-4.0.repo
echo "enabled=1" | sudo tee -a /etc/yum.repos.d/mongodb-org-4.0.repo
echo "gpgkey=https://www.mongodb.org/static/pgp/server-4.0.asc" | sudo tee -a /etc/yum.repos.d/mongodb-org-4.0.repo

sudo yum install -y mongodb-org

# 確保 MongoDB 端口未被防火牆阻止
sudo firewall-cmd --permanent --add-port=27017/tcp
sudo firewall-cmd --reload

# 確保 MongoDB 用戶具有對 /tmp 的寫權限
sudo chmod 1777 /tmp

# 啟動 MongoDB
sudo systemctl start mongod
sudo systemctl enable mongod

# 創建 MongoDB 用戶並賦予對數據庫的讀寫權限
mongo <<EOF
use admin
db.createUser({ user: "admin", pwd: "password", roles: [ { role: "userAdminAnyDatabase", db: "admin" } ] })
use coles_db
db.createUser({ user: "coles_user", pwd: "coles_password", roles: [ { role: "readWrite", db: "coles_db" } ] })
EOF

# 安裝 MongoDB 對 SELinux 的策略
git clone https://github.com/mongodb/mongodb-selinux
cd mongodb-selinux
make
sudo make install

# 安裝 Python 的必要依賴庫
pip3 install pymongo requests flask

# 整合 Coles 的商品信息，存儲歷史價格和時間，解決 Non-ASCII 問題
cd /opt
if [ ! -d "coles-scraper" ]; then
  git clone https://github.com/adambadge/coles-scraper.git
fi
cd coles-scraper

# 創建腳本來分析並提取商品信息，存儲到 MongoDB
cat << EOF > coles_scraper.py
import pymongo
import requests
from datetime import datetime
import re

# 連接到 MongoDB
try:
    client = pymongo.MongoClient("mongodb://coles_user:coles_password@localhost:27017/coles_db")
    db = client.coles_db
except Exception as e:
    print(f"連接到 MongoDB 時出錯: {e}")
    exit(1)

# 獲取商品信息，並處理 Non-ASCII 問題
def fetch_and_store_product_data():
    url = "https://coles.com.au/api/products"  # 示例 API 地址，具體 API 請替換為真實
    try:
        response = requests.get(url)
        response.raise_for_status()
        data = response.json()

        for item in data.get('products', []):
            product_name = re.sub(r'[\x80-\xff]', '', item.get('name', ''))
            product_price = item.get('price', 0.0)
            product_image = item.get('image_url', '')
            timestamp = datetime.now()
            # 存儲信息
            db.products.update_one({"name": product_name}, {"$set": {"name": product_name, "price": product_price, "image": product_image, "timestamp": timestamp}}, upsert=True)
            print(f"存儲商品: {product_name}, 價格: {product_price}")
    except requests.exceptions.RequestException as e:
        print(f"獲取商品信息時出錯: {e}")

if __name__ == "__main__":
    fetch_and_store_product_data()
EOF

python3 coles_scraper.py

# 創建 HTML 前端來顯示商品信息
cat << EOF > /var/www/html/index.html
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>商品列表</title>
</head>
<body>
    <h1>Coles 商品列表</h1>
    <div id="product-list"></div>
    <script>
        async function fetchProducts() {
            const response = await fetch('/products');
            const products = await response.json();
            let html = '';
            products.forEach(product => {
                html += `<div>
                    <img src="${product.image}" alt="商品圖片">
                    <p>名稱: ${product.name}</p>
                    <p>價格: $${product.price}</p>
                    <p>當前折扣: ${product.discount}</p>
                    <p>歷史最低價: $${product.lowest_price}</p>
                </div>`;
            });
            document.getElementById('product-list').innerHTML = html;
        }
        fetchProducts();
    </script>
</body>
</html>
EOF

# 配置 Flask 後端來提供商品信息 API
echo "from flask import Flask, jsonify
import pymongo

app = Flask(__name__)

try:
    client = pymongo.MongoClient(\"mongodb://coles_user:coles_password@localhost:27017/coles_db\")
    db = client.coles_db
except Exception as e:
    print(f\"連接到 MongoDB 時出錯: {e}\")
    exit(1)

@app.route('/products', methods=['GET'])
def get_products():
    products = db.products.find()
    result = []
    for product in products:
        result.append({
            'name': product['name'],
            'price': product['price'],
            'image': product['image'],
            'lowest_price': product.get('lowest_price', product['price']),
            'discount': product.get('discount', '無')
        })
    return jsonify(result)

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5000)" > flask_api.py

python3 flask_api.py &
