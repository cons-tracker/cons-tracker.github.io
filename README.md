# ระบบติดตามงานก่อสร้าง — สำนักงานทางหลวงที่ 5 (พิษณุโลก)

เว็บแอปและ PWA (ติดตั้งลงมือถือได้) สำหรับติดตามความก้าวหน้างานก่อสร้างทาง
- **ข้อมูลและบัญชีผู้ใช้** เก็บที่ [Supabase](https://supabase.com)
- **เว็บไซต์** deploy อัตโนมัติด้วย GitHub Pages ทุกครั้งที่ push ขึ้น branch `main`

## โครงสร้างไฟล์

| ที่อยู่ | คืออะไร |
|---|---|
| `web/` | ไฟล์ทั้งหมดที่ขึ้นเว็บ (GitHub Pages deploy โฟลเดอร์นี้) |
| `web/index.html` | ตัวแอป — **สร้างจาก `tools/build.ps1` ห้ามแก้ไฟล์นี้ตรง ๆ** |
| `web/config.js` | ค่าเชื่อมต่อ Supabase (URL + anon key) |
| `web/cloud.js` | ส่วนเชื่อมแอปกับ Supabase: ดึง/บันทึกข้อมูล ล็อกอิน จัดการผู้ใช้ และอัปเดตแบบเรียลไทม์ |
| `web/sw.js`, `web/manifest.json` | PWA: ติดตั้งเป็นแอป เปิดได้ตอนออฟไลน์ |
| `src/template.html` | **โค้ดหน้าจอและตรรกะของแอป** — แก้ที่ไฟล์นี้ |
| `src/bundle-base.html` | ไลบรารี ฟอนต์ และรูปที่ฝังไว้ (ปกติไม่ต้องแก้) |
| `supabase/schema.sql` | ตารางฐานข้อมูล สิทธิ์ (RLS) และโครงการตัวอย่าง |
| `supabase/sample-projects.sql` | โครงการตัวอย่างเพิ่มเติมแขวงละ 1 โครงการ (รันใน SQL Editor เมื่อต้องการ) |

## ตั้งค่า Supabase (ทำครั้งเดียว)

1. สร้างโปรเจกต์ใหม่ที่ <https://supabase.com/dashboard> (Region แนะนำ Southeast Asia (Singapore))
2. **SQL Editor** → New query → วางเนื้อหาไฟล์ `supabase/schema.sql` ทั้งไฟล์ → **Run**
3. **Authentication → Sign In / Providers → Email**
   - ปิด **Confirm email**
   - เปิด **Allow new users to sign up** ไว้ (Admin ใช้ตอนเพิ่มผู้ใช้จากในแอป ผู้ใช้ใหม่จะได้สิทธิ์ "ดูอย่างเดียว" จนกว่า Admin จะกำหนดบทบาทให้)
4. **Authentication → Users → Add user → Create new user**
   - Email: `admin@hw5.local` (ตอนล็อกอินในแอปพิมพ์แค่ `admin`)
   - ตั้งรหัสผ่าน แล้วติ๊ก **Auto Confirm User**
   - ผู้ใช้คนแรกของระบบจะได้บทบาท **Admin** อัตโนมัติ
5. **Project Settings → API** คัดลอก **Project URL** กับ **anon / publishable key** ไปใส่ใน `web/config.js`
   (ห้ามใช้ `service_role` / secret key)

## บทบาทผู้ใช้

| บทบาท | ทำอะไรได้ |
|---|---|
| ผู้เยี่ยมชม (ไม่ล็อกอิน) | ดูแผนที่ ภาพรวม และปฏิทินตรวจรับ |
| Executive — ผู้บริหาร | ดูแผนที่และปฏิทินตรวจรับ |
| Inspector — ช่างควบคุมงาน | กรอกผลงาน หมายเหตุ บันทึกรายงานประจำสัปดาห์ |
| Clerk — เสมียน | เพิ่ม/แก้ไขสัญญา รายการงาน แผนงาน และผลงาน |
| Admin — ผู้ดูแลระบบ | ทุกอย่าง รวมถึงเพิ่ม/ลบผู้ใช้ ตั้งรหัสผ่าน และกำหนดบทบาท |

สิทธิ์แก้ไขข้อมูลบังคับที่ฐานข้อมูล (Row Level Security) ไม่ใช่แค่ซ่อนปุ่ม
หมายเหตุ: ที่ระดับฐานข้อมูล บทบาท Inspector แก้ไขโครงการได้ทั้งโครงการ ส่วนการจำกัดให้แก้ได้เฉพาะผลงานควบคุมจากหน้าจอแอปเท่านั้น

## แก้ไขแอปแล้ว deploy

```powershell
# 1) แก้ src/template.html (หรือ web/cloud.js)
# 2) สร้าง web/index.html ใหม่
powershell -NoProfile -ExecutionPolicy Bypass -File tools/build.ps1
# 3) ทดสอบในเครื่อง: http://localhost:5500
powershell -NoProfile -ExecutionPolicy Bypass -File .claude/serve.ps1
# 4) commit และ push — GitHub Actions จะ deploy ให้เอง
git add -A
git commit -m "อธิบายสิ่งที่แก้"
git push
```

## ข้อควรรู้

- ถ้ามีคนแก้ **โครงการเดียวกัน** พร้อมกัน ระบบจะเก็บข้อมูลของคนที่บันทึกทีหลังสุด แก้คนละโครงการได้พร้อมกันโดยไม่มีปัญหา และทุกเครื่องเห็นการเปลี่ยนแปลงทันที (realtime)
- ตอนออฟไลน์ แอปเปิดได้และแสดงข้อมูลล่าสุดที่เก็บไว้ในเครื่อง การแก้ไขที่ทำตอนออฟไลน์จะถูกส่งขึ้นเซิร์ฟเวอร์เมื่อกลับมาออนไลน์
- สำรองข้อมูลได้ที่ Supabase → Database → Backups (แผนฟรีไม่มี backup อัตโนมัติ ควร export ตาราง `projects` เป็นระยะ)
- โปรเจกต์ Supabase แผนฟรีจะ **หยุดชั่วคราว** ถ้าไม่มีการใช้งาน 7 วัน ต้องเข้า Dashboard ไปกด Restore
