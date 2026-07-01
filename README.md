# wifi-audit

تست امنیت وای‌فای **خودت** با یک اسکریپت واحد. فقط روی شبکه‌ای که مالکش هستی اجرا کن — تست شبکهٔ دیگران بدون اجازه جرم است.

## نیازمندی‌ها
- لینوکس (کالی / اوبونتو)
- کارت وای‌فای سازگار با **monitor mode** (اینجکشن)
- اسکریپت خودش `aircrack-ng` را نصب می‌کند

## نصب روی لپ‌تاپ (ریپو خصوصی)

یک‌بار لاگین:
```bash
sudo apt install gh -y
gh auth login          # GitHub.com → HTTPS → Login with browser
```

بعد:
```bash
gh repo clone mariamtchelidze66/wifi-audit
cd wifi-audit
sudo ./wifi-audit.sh
```

## این اسکریپت چه می‌کند
1. تأیید مالکیت + بررسی root
2. نصب پیش‌نیازها (aircrack-ng)
3. انتخاب کارت وای‌فای و روشن‌کردن monitor mode
4. اسکن شبکه‌های اطراف
5. گرفتن handshake با deauth
6. تست پسورد با wordlist (پیش‌فرض `rockyou.txt`)
7. بازگرداندن کارت به حالت عادی

نتیجه: اگر پسورد در wordlist پیدا شد یعنی ضعیف است و باید عوضش کنی.

## wordlist دلخواه
```bash
sudo ./wifi-audit.sh /path/to/wordlist.txt
```
