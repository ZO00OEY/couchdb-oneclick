# CouchDB + Obsidian LiveSync 一键安装脚本

在 Linux 服务器上一条命令安装并配置 CouchDB，用于 Obsidian LiveSync 多设备实时同步。

## 适用系统

Debian 11/12 及 Ubuntu 20.04/22.04/24.04（需要 `apt` 包管理器）。

## 使用方法

```bash
curl -fsSL https://raw.githubusercontent.com/ZO00OEY/couchdb-oneclick/master/setup-couchdb.sh | sudo bash
```

脚本会自动完成：
- 安装 CouchDB（添加 Apache 官方源）
- 生成随机安全密码
- 配置单节点模式
- 创建 `obsidian` 数据库
- 写入认证、CORS 等 9 项必需配置
- 验证全部配置
- 输出连接信息

## 更新并运行

```bash
curl -fsSL https://raw.githubusercontent.com/ZO00OEY/couchdb-oneclick/master/setup-couchdb.sh | sudo bash
```

## 运行完成后

脚本会在屏幕醒目显示连接信息，同时保存一份到当前目录下的 `couchdb-credentials.txt`。

将以下信息填入 Obsidian LiveSync 插件设置：

| 字段 | 值 |
|------|-----|
| 服务器地址 | `http://你的服务器IP:5984` |
| 用户名 | `obsidian_user` |
| 密码 | 脚本生成的随机密码 |
| 数据库名 | `obsidian` |

## 修改密码

CouchDB 管理员密码不以明文保存在服务器文件中。如需修改，请用浏览器访问：

```
http://你的服务器IP:5984/_utils
```

登录后在用户管理页面操作。

## 防火墙设置

确保服务器 5984 端口对外开放：

```bash
# ufw 防火墙
sudo ufw allow 5984/tcp

# firewalld 防火墙
sudo firewall-cmd --permanent --add-port=5984/tcp
sudo firewall-cmd --reload
```

云服务器请在安全组中添加入站规则 TCP 5984。

## 安全建议

- 不建议将 CouchDB 直接暴露在公网，建议配合 Nginx 反向代理 + HTTPS
- 在 Obsidian LiveSync 插件中开启端到端加密
- 定期备份 CouchDB 数据目录
