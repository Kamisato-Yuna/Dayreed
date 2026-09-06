# Dayreed 产品官网

官网：<https://kamisato-yuna.github.io/Dayreed/>。源码在 `site/`，纯 HTML/CSS/JavaScript，无前端运行依赖、外部字体或遥测。产品功能演示使用手写合成数据，并明确标注为功能示意，不是原生 App 截图。

## 本地预览

```sh
python3 -m http.server 4173 --directory site --bind 127.0.0.1
```

浏览器打开 `http://127.0.0.1:4173`。检查时间线/日报/周报切换、键盘方向键、理念展开、发布链接，以及移动端与减少动态效果。

## GitHub Pages

仓库 Pages 来源设为 GitHub Actions。`Product Pages` 工作流在 main 的官网文件变化、Release 发布/编辑/删除/取消发布或手动触发时部署，只上传 `build/site`。

`python3 script/build_site.py` 将公开资源复制到 `build/site`，通过 GitHub API 获取最新正式 Release，生成 `release.json`。未发布时明确显示尚无正式 Release；已发布时链接到该版本的 GitHub 发布页，由用户查看真实资产及说明。请求失败时构建失败，保留前一次在线站点；不会把网络错误写成“尚未发布”。页面自身读取快照失败时仍有可用的 Releases 链接。页面标注快照日期，实时状态以 GitHub 为准。

此工作流不制作、签名、上传或发布 App，也不改动 App 更新 feed。应用正式发布仍遵循独立发布流程。

## 视觉资源

- `assets/reed.svg`：根据 Dayreed 正式三株芦苇 SVG 图层制作的网页适配版；App 的正式图标继续以 Icon Composer 工程为准。
- `assets/glass-reeds.jpg`：内置 Image Gen 生成的官网装饰插画，不代表 App 界面。提示词：白色与浅冰蓝背景，右侧三株通透玻璃芦苇和光学玻璃圆球，底部轻盈玻璃波纹，左侧留白，无文字、无 UI。
- 正文使用系统字体，展示标题使用系统宋体；CSS 定义白色底、墨蓝文字、冰蓝光线、玻璃边缘和柔和阴影。支持系统减少动态效果设置。
