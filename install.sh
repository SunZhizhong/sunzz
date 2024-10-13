#!/bin/bash

# 確保腳本在出現錯誤時停止
set -e

# 更新系統並安裝必須的依賴包
yum update -y

# 安裝 EPEL (Extra Packages for Enterprise Linux)
yum install -y epel-release

# 安裝 Python 3.8 和 pip
yum install -y python38 python38-pip

# 創建 Python 3.8 的符號鏈接（確保版本一致）
ln -sf /usr/bin/python3.8 /usr/bin/python3
ln -sf /usr/bin/pip3.8 /usr/bin/pip3

# 安裝 MongoDB
cat <<EOF > /etc/yum.repos.d/mongodb-org-6.0.repo
[mongodb-org-6.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/7/mongodb-org/6.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-6.0.asc
EOF

yum install -y mongodb-org

# 啟動和設置 MongoDB 開機自啟
systemctl start mongod
systemctl enable mongod

# 確保 MongoDB 的端口 27017 沒有被防火牆阻止
firewall-cmd --zone=public --add-port=27017/tcp --permanent
firewall-cmd --reload

# 確保 /tmp 具有寫權限
chmod 1777 /tmp

# 創建 MongoDB 用戶並賦予讀寫權限
mongo <<EOF
use admin
db.createUser(
  {
    user: "python_user",
    pwd: "secure_password",
    roles: [ { role: "readWrite", db: "coles_db" } ]
  }
)
EOF

# 安裝必備 Python 庫
pip3 install pymongo requests beautifulsoup4 flask

# 下載 Coles 商品信息獲取代碼
curl -o coles_scraper.ipynb https://raw.githubusercontent.com/adambadge/coles-scraper/master/coles.ipynb

# 編寫 Python 腳本來抓取商品信息並存儲至 MongoDB
cat <<EOF > coles_scraper.py
import pymongo
import requests
import time
from bs4 import BeautifulSoup

# 連接到 MongoDB
try:
    client = pymongo.MongoClient("mongodb://python_user:secure_password@localhost:27017/")
    db = client["coles_db"]
    col = db["products"]
except Exception as e:
    print("無法連接到 MongoDB:", e)
    exit(1)

# 獲取商品信息並存儲到 MongoDB
try:
    response = requests.get("https://coles.com.au/api/products")
    response.encoding = 'utf-8'
    products = response.json()
    
    for product in products:
        product_name = product.get("name")
        product_price = product.get("price")
        
        # 插入到 MongoDB
        col.update_one(
            {"name": product_name},
            {"$set": {"price": product_price, "last_updated": time.time()}},
            upsert=True
        )
        
    print("成功存儲商品信息")
except Exception as e:
    print("獲取商品信息失敗:", e)
    exit(1)
EOF

# 執行抓取並存儲商品信息
python3 coles_scraper.py

# 編寫 Flask 前端顯示頁面
cat <<EOF > app.py
from flask import Flask, render_template
import pymongo

app = Flask(__name__)

# 連接到 MongoDB
client = pymongo.MongoClient("mongodb://python_user:secure_password@localhost:27017/")
db = client["coles_db"]
col = db["products"]

@app.route('/')
def index():
    products = list(col.find())
    return render_template('index.html', products=products)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF

# 創建前端 HTML 頁面
mkdir templates
cat <<EOF > templates/index.html
<!DOCTYPE html>
<html lang="zh-Hans">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Coles 商品價格查詢</title>
</head>
<body>
    <h1>Coles 商品價格查詢</h1>
    <table border="1">
        <tr>
            <th>商品名稱</th>
            <th>價格</th>
            <th>最近更新時間</th>
        </tr>
        {% for product in products %}
        <tr>
            <td>{{ product['name'] }}</td>
            <td>{{ product['price'] }}</td>
            <td>{{ product['last_updated'] | date("%Y-%m-%d %H:%M:%S") }}</td>
        </tr>
        {% endfor %}
    </table>
</body>
</html>
EOF

# 運行 Flask 應用
python3 app.py

echo "一鍵安裝完成，前端服務器已經啟動，請打開瀏覽器並訪問 http://<你的服務器IP>:5000"
