# wifi-audit

تست امنیت وای‌فای **خودت** با یک اسکریپت واحد. فقط روی شبکه‌ای که مالکش هستی اجرا کن — تست شبکهٔ دیگران بدون اجازه جرم است.

## نیازمندی‌ها
- لینوکس (کالی / اوبونتو)
- کارت وای‌فای سازگار با **monitor mode** (اینجکشن)
- اسکریپت خودش `aircrack-ng` را نصب می‌کند

## نصب و اجرا (یک دستور، کپی کن — بدون git clone)

```bash
curl -fsSL https://raw.githubusercontent.com/mariamtchelidze66/wifi-audit/main/install.sh | sudo bash
```

یا با wget:

```bash
wget -qO- https://raw.githubusercontent.com/mariamtchelidze66/wifi-audit/main/install.sh | sudo bash
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
curl -fsSL https://raw.githubusercontent.com/mariamtchelidze66/wifi-audit/main/wifi-audit.sh -o wifi-audit.sh && sudo bash wifi-audit.sh /path/to/wordlist.txt
```
