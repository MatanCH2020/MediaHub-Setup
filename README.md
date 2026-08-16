# MediaHub — התקנה / Setup

מתקין את MediaHub על Windows. הדבק את השורה הבאה ב-PowerShell:

Installs MediaHub on Windows. Paste this into PowerShell:

```powershell
irm https://raw.githubusercontent.com/MatanCH2020/MediaHub-Setup/main/bootstrap.ps1 | iex
```

תתבקש להזין מפתח הפעלה, ואז להיכנס לחשבון GitHub שלך.
You will be asked for an activation key, then to sign in to GitHub.

**אין לך מפתח?** ההתקנה בהזמנה בלבד — פנה למתן.
**No key?** Installation is by invitation — contact Matan.

---

## מה יש בריפו הזה / What is in this repository

זה החלק הציבורי היחיד של MediaHub, והוא לא מכיל קוד אפליקציה:

This is the only public part of MediaHub, and it contains no application code:

| קובץ / File | תפקיד / Purpose |
|---|---|
| `bootstrap.ps1` | בודק את המפתח, מחבר ל-GitHub, מוריד את הריפו הפרטי ומריץ את המתקין |
| `allow.json` | SHA-256 של המפתחות שהונפקו |

`allow.json` מכיל **hashes בלבד**. אי אפשר להפוך hash בחזרה למפתח, ולכן הקובץ בטוח לפרסום.

`allow.json` holds **hashes only**. A hash cannot be reversed into a key, so publishing it leaks nothing.
