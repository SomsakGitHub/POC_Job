# TradePulse (POC) — เอกสารออกแบบ

สถานะ: **ร่าง รออนุมัติ** · 2026-11-22 · "TradePulse" เป็นชื่อชั่วคราว

วิธีอ่าน: **[คุณ]** = สิ่งที่คุณบอกเอง · **[ผม]** = ข้อเสนอ/การตัดสินใจของผม พร้อมเหตุผล (แก้ได้ทุกข้อ)

## 1. เจตนาและเหตุผล

- **[คุณ]** อยากได้แอป Swift ที่ใช้ข้อมูลเรียลไทม์ผ่าน WebSockets, gRPC และ REST API โดยกราฟหุ้น การส่งคำสั่งซื้อขาย และการประมวลผลธุรกรรมต้องมี latency ต่ำมาก
- **[คุณ]** เมื่อเปิดให้ทีมของ Kasikorn Securities ดู อยากให้เขาเห็นว่า "แอปทำงานได้"
- ที่มา: ประกาศ Technical Lead – Mobile Engineering (FinTech/Investment Platform) ของ Kasikorn Securities (JobsDB #95746704) ระบุทักษะเหล่านี้ตรง ๆ: native Swift, real-time streaming ด้วย WebSockets/gRPC, REST, latency ต่ำสำหรับกราฟหุ้น/ส่งคำสั่ง/ประมวลผลธุรกรรม
- **[ผม]** ตีความว่านี่คือแอปต้นแบบ (POC) ไว้โชว์ฝีมือประกอบการสมัคร ใบสมัครแบบ Quick apply ถามนายจ้างข้อเดียวและไม่เห็นว่าขอ portfolio แอปจึงเป็นหลักฐานเสริม ไม่ใช่เงื่อนไข
- **[ผม]** "ทำงานได้" = ระบบจริงวิ่งครบวงจรบนโปรโตคอลจริง (ไม่ใช่ภาพจำลอง) และ latency ต้อง *วัดให้เห็น* ไม่ใช่อ้างลอย ๆ
- ขนาดงาน: โปรเจกต์เต็มตัว = เซิร์ฟเวอร์ตลาดจำลอง + แอป iOS + ชุดวัดผลและทดสอบ

## 2. เป้าหมาย / ไม่ใช่เป้าหมาย / สิ่งที่ถือว่าล้มเหลว

**เป้าหมาย**
1. แอป iOS (Swift 6, SwiftUI) มี watchlist สด, กราฟแท่งเทียนสด, ใบสั่งซื้อขาย (Market/Limit, ซื้อ/ขาย, ยกเลิก), รายการคำสั่งและธุรกรรม, พอร์ต — ทั้งหมดรับ-ส่งผ่าน WebSocket/gRPC/REST จริง
2. เซิร์ฟเวอร์ตลาดจำลองเขียนด้วย Swift: ราคาแบบหุ้น SET, จับคู่คำสั่ง, บัญชีแยกประเภท (ledger)
3. Latency ต่ำและ *วัดได้ในแอป*: tick→หน้าจอ, ส่งคำสั่ง→ยืนยัน (p50/p95/p99), เฟรมตก, พร้อมโหมดโหลดหนักหลายพัน tick/วินาทีที่ UI ไม่ค้าง
4. ความทนทานแบบแอปการเงิน: reconnect + resync, ส่งคำสั่งซ้ำได้ปลอดภัย (idempotent), ไม่เสียหรือซ้ำเหตุการณ์ fill, ledger ถูกต้องตามกฎ
5. รันง่ายด้วยคำสั่งไม่กี่คำสั่ง มี README (สถาปัตยกรรม + ตัวเลขที่วัดจริง + ข้อจำกัด) และมีเทสต์

**ไม่ใช่เป้าหมาย (รอบแรก)**
- ข้อมูลตลาดจริง / โบรกเกอร์จริง / เงินจริง
- Face ID, TLS/certificate pinning, MFA — ออกแบบให้เสียบเพิ่มได้ แต่เป็นรอบถัดไป
- iPad / Mac / Android, push notification, อินดิเคเตอร์ขั้นสูง, App Store/TestFlight
- รันบนเครื่องจริง (ทำภายหลังได้ ยังไม่รับรองในรอบแรก)

**ถือว่าล้มเหลวแม้โค้ดจะรันได้**
- ใช้ของปลอมในแอปแทนโปรโตคอลจริง
- อ้าง latency โดยไม่มีตัวเลขที่วัดจริง
- UI กระตุกหรือค้างเมื่อโหลดหนัก
- แสดงข้อมูลจำลองเหมือนข้อมูลจริง หรือใช้ชื่อ/โลโก้ของ Kasikorn ในแอป (ต้องมีป้าย "SIMULATED DATA" ชัดเจน)
- ทำเซิร์ฟเวอร์เกินจำเป็น (ไม่ microservices ไม่ฐานข้อมูลภายนอก ไม่ Kafka)

## 3. "ทำงานได้" หมายถึงอะไร — เกณฑ์ตรวจรับ = เดโม 2 นาที

| เวลา | สิ่งที่เห็น | พิสูจน์อะไร |
|---|---|---|
| 0:00 | เปิดแอป: watchlist ~12 หุ้น ราคาวิ่งสด | REST (รายชื่อหุ้น) + WebSocket |
| 0:20 | เปิดหุ้น 1 ตัว: ประวัติโหลด แท่งเทียนขยับสด มีป้าย latency (p50/p99) | pipeline + กราฟ + การวัด |
| 0:45 | ซื้อ Market → ยืนยัน → fill (แตกหลายราคาได้) → พอร์ต/เงินสด/ธุรกรรมอัปเดต | gRPC + ledger |
| 1:10 | วาง Limit ต่ำกว่าตลาด → ค้าง → ยกเลิก; ส่งคำสั่งผิด (tick/lot/เงินไม่พอ) → ถูกปฏิเสธพร้อมเหตุผล | วงจรชีวิตคำสั่ง + validation |
| 1:30 | Lab: ตัดการเชื่อมต่อ → แอปแสดงสถานะ → ต่อใหม่ → ข้อมูลและคำสั่งตรงกัน ไม่ซ้ำไม่ตก | reconnect / resync / idempotency |
| 1:45 | Lab: โหมดโหลดหนัก (หลายพัน tick/วินาที) → UI ลื่น ตัวเลข p99 และเฟรมตกแสดงสด | latency ภายใต้โหลด |

เงื่อนไขเพิ่ม: `make test` ผ่านทั้งหมด และ README มีตัวเลขที่วัดจากการรันจริงบน Simulator

## 4. ข้อจำกัดและสภาพแวดล้อม (ตรวจแล้วบนเครื่องนี้)

- macOS (arm64), Xcode 27.2 (Swift 6.4.2), iOS 27.2 SDK; Simulator ติดตั้งแล้วตั้งแต่ iOS 18.6 ถึง 27.2
- มี Node 22, Homebrew, CocoaPods; **ไม่มี** protoc, xcodegen, Flutter, Android SDK
- เข้าถึง GitHub ได้ (ดึงแพ็กเกจ SwiftPM ได้: gRPC Swift 2, Hummingbird 2, swift-protobuf ฯลฯ); จาก `Package.swift` ของแพ็กเกจเหล่านี้: gRPC Swift 2 ต้อง macOS 15+ / iOS 18+ และ Swift tools 6.1+, hummingbird-websocket ต้อง Swift tools 6.2+ — เครื่องนี้ (Swift 6.4.2) รองรับ
- โฟลเดอร์ว่าง เป็น git repo ที่ยังไม่มี commit บน `main` — ผมจะไม่ commit จนกว่าคุณสั่ง
- ไม่ต้องติดตั้ง `protoc`: swift-protobuf สร้าง `protoc` เองผ่าน SwiftPM ได้ และ grpc-swift-protobuf มี plugin `generate-grpc-code-from-protos` ครอบให้ (อ่านจากซอร์สบน GitHub แล้ว ยังไม่ได้ลองรันจริง; รอบแรกคอมไพล์ `protoc` ใช้เวลานาน) — มีเพียง `xcodegen` ที่ต้องติดตั้งผ่าน Homebrew ผมจะขออนุญาตก่อน
- โค้ดที่ generate (protobuf/gRPC) และไฟล์ `.xcodeproj` จะถูกเก็บใน repo เพื่อให้คนโคลนไปเปิดได้ด้วย Xcode อย่างเดียว
- cleartext บน localhost: ตั้ง `NSAllowsLocalNetworking`; รอบแรกไม่มี TLS

## 5. ทางเลือกที่พิจารณา

**ภาพรวม (ผมเลือก ก — คุณฝากเรื่องวิธีทำไว้กับผม รอยืนยัน)**

| ทาง | ข้อดี | ข้อเสีย | ผล |
|---|---|---|---|
| **ก. Swift ทั้งสแตก**: แอป SwiftUI + ตลาดจำลองด้วย Swift (Hummingbird = REST/WebSocket, gRPC Swift 2 = สั่งซื้อขาย) ใน repo เดียว ใช้ `.proto` ชุดเดียว | เครื่องมือเดียว สัญญาตรงกันเสมอ เล่าเรื่อง full-stack Swift ได้ | ตั้งเซิร์ฟเวอร์ Swift ช้ากว่า Node เล็กน้อย | **เลือก** |
| ข. แอป Swift + เซิร์ฟเวอร์ Node | เซิร์ฟเวอร์เสร็จเร็วกว่า | สองเครื่องมือ สองชุดสัญญา เรื่องเล่าอ่อนลง | ตัดออก |
| ค. ต่อฟีดสาธารณะจริง (เช่นคริปโต) + เซิร์ฟเวอร์สั่งซื้อเล็ก | กราฟดูจริง | ไม่ใช่หุ้น พึ่งอินเทอร์เน็ต/รูปแบบบุคคลที่สาม ทดสอบโหลดไม่ได้ | ตัดออกเป็นแกนหลัก (แอปรับแหล่งข้อมูลผ่าน protocol จึงเสียบเป็นตัวเสริมทีหลังได้) |

**การตัดสินใจย่อย (ทุกข้อเป็น [ผม])**

| เรื่อง | เลือก | ทางอื่น | เหตุผล |
|---|---|---|---|
| กราฟ | SwiftUI `Canvas` วาดเอง ดึงสถานะล่าสุดตามจังหวะหน้าจอ | Swift Charts; Metal | Swift Charts ไม่ได้ออกแบบมาสำหรับอัปเดตทุก tick (คาดการณ์ ยังไม่ได้วัด); Metal เพดานสูงกว่าแต่ข้อมูลระดับร้อยแท่งไม่ได้ประโยชน์และเสี่ยงสูง — วางกราฟหลัง protocol เพื่อสลับได้ |
| ข้อมูลบน WebSocket | Protobuf ไบนารี รวมเป็นเฟรม (batch ≤ ~5 ms) + JSON text เฉพาะข้อความควบคุม | JSON ล้วน; ไบนารีเขียนเอง | แชร์ schema กับ gRPC, เล็กและ decode เร็วพอ — ถ้าวัดแล้วเป็นคอขวดค่อยเปลี่ยนเป็นแพ็กไบนารีเอง |
| ไคลเอนต์ WebSocket | `URLSessionWebSocketTask` | Network.framework ตรง ๆ | โค้ดน้อย เสถียร ส่วนต่างต้นทุนเล็กเมื่อเทียบกับการประมวลผลระดับแอป — ถ้าวัดแล้วไม่พอค่อยลงลึก |
| เซิร์ฟเวอร์ | Hummingbird 2 (REST + WebSocket) กับ gRPC Swift 2 ใน process เดียว คนละพอร์ต | Vapor; SwiftNIO ล้วน | เบา รองรับ Swift 6 ลดโค้ดกาว |
| ราคา | จำนวนเต็ม (satang, `Int64`) ทุกที่ | `Double` / `Decimal` | เลี่ยงความคลาดเคลื่อนทศนิยม แปลงเป็นข้อความที่ขอบ UI เท่านั้น |
| เป้าหมายรัน | iOS 18+ บน Simulator (iPhone, แนวตั้ง) | เครื่องจริง | gRPC Swift 2 ต้องการ iOS 18+ (ตรวจจาก `Package.swift` แล้ว); เครื่องจริงต้อง signing/LAN |
| โปรเจกต์ Xcode | สร้างด้วย XcodeGen เก็บทั้ง spec และ `.xcodeproj` | เขียนมือ | แก้ง่าย ทำซ้ำได้ |

## 6. การออกแบบ

### 6.1 ภาพรวมระบบ

```
┌──────────── แอป iOS (TradePulse) ───────────┐          ┌──────── ExchangeServer (Swift, macOS) ────────┐
│ SwiftUI: Watchlist · Chart · OrderTicket ·   │          │ Market simulator ──► MarketHub (conflating)   │
│          Orders · Portfolio · Lab            │          │                                                │
│ ──────────────────────────────────────────── │  WS      │ WebSocket /ws/market  (Protobuf frames)        │
│ Pipeline: decode → MarketState (latest-wins) │◄────────►│ REST      /v1/*       (JSON)                   │
│           → display-link pull → Canvas       │  REST    │ gRPC      OrderService (HTTP/2, Protobuf)      │
│ Clients: MarketData (WS) · Trading (gRPC)    │◄────────►│                                                │
│          · Rest (URLSession)                 │  gRPC    │ Matching sim + OrderBook ──► Ledger           │
│ LatencyRecorder (histograms) · ClockSync     │◄────────►│ Event log (event_seq) · Lab controls          │
└──────────────────────────────────────────────┘          └────────────────────────────────────────────────┘
```

### 6.2 เซิร์ฟเวอร์ตลาดจำลอง (ExchangeServer)

- **ตลาด**: ~12 หุ้นแบบ SET (ชื่อย่อจริง ราคาสมมติทั้งหมด) ราคาเดินแบบ random walk + ความผันผวนเปลี่ยนช่วง ปัดเข้า tick size (ตารางแบบ SET เป็นพารามิเตอร์ของการจำลอง ไม่ใช่คำกล่าวอ้างว่าตรงกฎจริง); lot = 100 หุ้น; กรอบราคา ±30% จากราคาอ้างอิง
- **Order book สังเคราะห์** 5 ระดับต่อฝั่ง เติมเต็มต่อเนื่อง; อัตราปกติ ~20 update/วินาที/หุ้น; โหมดหนัก ≥ 5,000 update/วินาทีรวม (ค่าเริ่มต้น ปรับได้)
- **แท่งเทียน** 1s/1m/5m รวมที่ server; มีประวัติสร้างล่วงหน้าแบบ deterministic (seed) กราฟจึงไม่ว่างตอนเริ่ม
- **คำสั่ง**: Market, Limit (Day); ตรวจ tick/lot/กรอบราคา/กำลังซื้อ/จำนวนหุ้นที่ถือ (ไม่มี short); Market ไล่กินหลายระดับ (fill หลายราคาและบางส่วนได้); Limit ที่ข้ามราคาจับคู่ก่อนแล้วที่เหลือค้างใน book; Limit ที่ค้างถูก fill เมื่อราคาจำลองผ่าน; ยกเลิกได้
- **สถานะ**: `PENDING → ACCEPTED → PARTIALLY_FILLED → FILLED | CANCELLED | REJECTED` (reject ที่เป็นเหตุผลทางธุรกิจส่งกลับเป็นข้อมูล ไม่ใช่ gRPC error)
- **Idempotency**: `client_order_id` ซ้ำ = ผลเดิม ไม่สร้างคำสั่งใหม่
- **Event log**: เหตุการณ์ของบัญชีมี `event_seq` เพิ่มทีละ 1 เก็บแบบ ring buffer จำกัดขนาดเพื่อให้ client resume ได้; `server_epoch` (สุ่มต่อการสตาร์ท) ให้ client รู้ว่าเซิร์ฟเวอร์ถูกรีสตาร์ท → ล้างสถานะแล้ว sync ใหม่พร้อมแจ้งผู้ใช้
- **Ledger**: บัญชีเดโม 1 บัญชี เริ่ม ฿1,000,000; ทุก fill สร้างรายการธุรกรรม (id, order, symbol, side, qty, price, ค่าคอมมิชชันจำลองที่ตั้งค่าได้, ผลต่อเงินสด, `ledger_seq`); กฎที่ต้องเป็นจริงเสมอ: เงินสด ≥ 0, จำนวนหุ้น ≥ 0, Σ fill = filled_qty, Σ รายการ = การเปลี่ยนของเงินสด
- **สถานะอยู่ในหน่วยความจำล้วน** (รีสตาร์ท = รีเซ็ต ไม่มีฐานข้อมูล); ไม่มี auth รอบแรก แต่เว้นช่องรับ token ไว้
- **ปุ่มควบคุม Lab** (REST admin): ปรับอัตรา tick, โหมดโหลดหนัก, ใส่ latency/jitter ฝั่งส่ง, ทิ้งการเชื่อมต่อ, ทำให้ลำดับอัปเดตขาดเพื่อทดสอบ resync, รีเซ็ตบัญชี

### 6.3 สัญญาการสื่อสาร

**WebSocket `/ws/market`**
- Client → server (JSON text): `subscribe` / `unsubscribe` (รายชื่อหุ้น), `ping` (พร้อมเวลา client สำหรับ clock sync), `resync(symbol)`
- Server → client (Protobuf binary): `MarketFrame { server_send_ns, frame_seq, repeated SymbolUpdate }`
- **`SymbolUpdate` เป็นสถานะล่าสุดของหุ้นตัวนั้น ไม่ใช่แค่ delta**: last, bid/ask (+ปริมาณ), ปริมาณวัน, และ **แท่งเทียนปัจจุบัน (OHLCV) ที่ server รวมให้แล้ว** พร้อม `seq` ต่อหุ้น → conflate แบบ latest-wins ได้โดยกราฟยังถูกต้อง และกู้สถานะได้จากอัปเดตถัดไป (ประวัติที่ขาดกู้ผ่าน REST)
- ส่งสถานะเต็มทันทีที่ subscribe; ถ้า client อ่านไม่ทัน server รวมอัปเดตต่อหุ้น (คิวขาออกมีขอบเขต)

**gRPC `OrderService`** (HTTP/2, deadline ทุกคำเรียก)
- `SubmitOrder` (unary, idempotent ด้วย `client_order_id`) → ack พร้อมเวลาประมวลผลฝั่ง server
- `CancelOrder` (unary)
- `StreamOrderEvents(from_event_seq)` (server streaming, resume ได้): `oneof { Accepted, Rejected, Fill, Cancelled, LedgerEntry }` พร้อม `event_seq`, `server_epoch`
- ช่อง gRPC เชื่อมต่อค้างไว้ล่วงหน้า (pre-warmed + keepalive) ไม่มีการตั้ง connection บนเส้นทางส่งคำสั่ง

**REST (JSON)**
- `GET /v1/symbols` (ข้อมูลอ้างอิง, ETag), `GET /v1/candles?symbol=&interval=&limit=`, `GET /v1/account`, `GET /v1/transactions?cursor=`, `GET /v1/time`, `GET /healthz`
- `POST /v1/admin/...` สำหรับปุ่ม Lab

### 6.4 แอป iOS

- Swift 6 (strict concurrency), SwiftUI + Observation, structured concurrency; iOS 18+
- **โมดูล**: `TradeCore` (โมเดล, ราคา fixed-point, ring buffer, ตัวรวมแท่งเทียน, ตัวบันทึก latency — Swift ล้วน เทสต์ได้บน macOS) · `TradeNetworking` (ไคลเอนต์ 3 ชนิดหลัง protocol + backoff/reconnect + clock sync) · App target (หน้าจอ + จุดประกอบ)
- **Data pipeline (หัวใจ)**
  1. ลูปรับ WebSocket ส่ง `Data` ให้ตัว decode นอก main thread
  2. อัปเดตเข้า `MarketState` (ล็อกเบา ๆ เช่น `Mutex`) ต่อหุ้น O(1) ต่ออัปเดต ไม่สร้างอ็อบเจ็กต์ใหม่บนเส้นทางร้อน
  3. `CADisplayLink` บน main actor ดึงสแนปช็อตสถานะล่าสุดของหุ้นที่แสดงอยู่ **ครั้งเดียวต่อเฟรม** (หลาย tick → หนึ่งการวาด) แล้วค่อยแจ้ง SwiftUI เมื่อมีการเปลี่ยน
  4. ตัวบันทึก latency ใช้ histogram แบบ bucket ตายตัวนอก main เพื่อให้การวัดไม่รบกวนสิ่งที่วัด
- **นโยบาย backpressure**: ข้อมูลตลาด = conflate (latest-wins); คำสั่ง/เหตุการณ์ = ห้ามทิ้ง เรียงลำดับ resume ได้
- **เส้นทางคำสั่ง**: UUID ต่อการส่ง; แสดงแถว "pending" ทันที; ส่งผ่าน gRPC พร้อม deadline; ถ้า `UNAVAILABLE`/หมดเวลา → ส่งซ้ำด้วย id เดิม; สถานะคำสั่ง/พอร์ต **คำนวณจากสตรีมเหตุการณ์เท่านั้น** (แหล่งความจริงเดียว) แล้วเทียบกับ `GET /v1/account` เพื่อตรวจว่าไม่เพี้ยน
- **ความปลอดภัยเชิงใช้งาน**: ปิดปุ่มส่งคำสั่งเมื่อช่องคำสั่งหลุดหรือราคาค้างเกินเกณฑ์ (ไม่ส่งคำสั่งด้วยราคาเก่า) และแสดงแถบสถานะการเชื่อมต่อ
- **กราฟ**: `Canvas` วาดแท่งเทียน + ปริมาณ + เส้นราคาล่าสุด เฉพาะช่วงที่มองเห็น; pan/zoom; สลับ 1s/1m/5m และ Candle/Line; รายงานต้นทุนต่อเฟรมใน Lab
- **หน้าจอ**: แท็บ Market · Orders · Portfolio · Lab (ภาษา UI เป็นอังกฤษ ชื่อบริษัทแสดงภาษาไทย)

```
┌──────────────────────────────┐
│ PTT  ปตท.        SIMULATED   │
│ 34.25  ▲ +0.50 (+1.48%)      │
│ tick→screen p50 3 ms · p99 9 │  ← ป้าย latency
│ ┌──────────────────────────┐ │
│ │   ▮ ▮▯ ▮  ▯▮ ▮▮ ▯ ▮▮     │ │  ← แท่งเทียน (สด)
│ │   ▁▂▁▃▂▁▂▃▂▁▂▃▂▁▂        │ │  ← ปริมาณ
│ └──────────────────────────┘ │
│ [1s] [1m] [5m]  Candle | Line│
│ ┌────────┐ ┌────────┐        │
│ │  BUY   │ │  SELL  │        │
│ └────────┘ └────────┘        │
│ Recent fills …               │
└──────────────────────────────┘
```

### 6.5 การวัด latency

| ตัวชี้วัด | จุดเริ่ม | จุดจบ |
|---|---|---|
| tick→app | เวลา server ก่อนส่งเฟรม | WebSocket รับเฟรมที่ฝั่งแอป |
| tick→applied | เวลา server | อัปเดตเข้า `MarketState` เสร็จ |
| tick→render | เวลา server | commit เฟรมภาพที่มี tick นั้น (จาก display link) |
| order submit→ack | ก่อนเรียก `SubmitOrder` | ได้ response (แยกเวลาประมวลผลฝั่ง server ที่ส่งกลับมา) |
| order submit→fill | ก่อนเรียก | เหตุการณ์ fill มาถึงสตรีม |
| frame hitch | — | ระยะห่างเฟรม > 1.5× งบเวลา (นับจำนวนและสัดส่วน) |

- เวลาเป็น wall-clock นาโนวินาที; clock offset ประเมินด้วย ping/pong หลายครั้งแล้วเลือกตัวอย่างที่ RTT ต่ำสุด (บน Simulator ที่รันเครื่องเดียวกัน offset ≈ 0)
- **เป้าหมายเริ่มต้น (รายงานตามที่วัดได้ ห้ามอ้างโดยไม่มีตัวเลข):** tick→render p99 ≤ 2 เฟรม (~33 ms ที่ 60 Hz) ที่โหลดรวม 1,000 tick/วินาที; submit→ack p99 ≤ 50 ms บน loopback ถ้าไม่ถึงให้รายงานตามจริงพร้อมสาเหตุ
- **ข้อควรระวังที่ต้องเขียนใน README**: ทั้งหมดวัดบน loopback ในเครื่องเดียว จึงสะท้อนต้นทุนฝั่งแอป/pipeline เป็นหลัก ไม่ใช่เครือข่ายจริง — มีโปรไฟล์ใส่ latency/jitter จาก Lab เพื่อดูพฤติกรรมเมื่อเครือข่ายแย่

### 6.6 การทดสอบและการตรวจสอบ

- **Unit** (Swift Testing, `swift test` บน macOS): ราคา fixed-point + tick/lot, state machine ของคำสั่ง, การไล่กินหลายระดับ/fill บางส่วน, กฎ ledger (สุ่มจำนวนมากตรวจ invariant), ตัวรวมแท่งเทียน, ring buffer, conflation, histogram, ตารางเวลา backoff
- **Integration**: สตาร์ท server ใน process บนพอร์ตชั่วคราว ใช้ไคลเอนต์จริง: subscribe ได้ tick เรียงลำดับ, ลำดับขาด → resync, submit → เหตุการณ์ครบ, ส่งซ้ำด้วย id เดิมไม่เกิดคำสั่งซ้ำ, resume จาก `event_seq`, `server_epoch` เปลี่ยน, `GET /v1/account` ตรงกับ ledger
- **Performance**: รันโหมดหนักแล้ววัด tick→render และ hitch (รายงาน ไม่ใช่เกณฑ์ผ่าน/ตก)
- **E2E**: build และรันแอปบน Simulator (iOS 27.2 และสโมกเทสต์ที่ iOS 18.6 ซึ่งเป็นขั้นต่ำ) เดินตามเดโม 2 นาที เก็บภาพหน้าจอ/ตัวเลขลง `docs/results/`
- กฎ: ไม่อ้างว่า "เสร็จ/ผ่าน" ถ้าไม่มีผลที่รันสดมายืนยัน

### 6.7 โครงสร้าง repo และคำสั่ง (ร่าง — แผนงานกำหนดรายละเอียด)

```
POC_Job/
  Package.swift        # Contracts, ExchangeCore, ExchangeServer (exe), TradeCore, TradeNetworking + tests
  Proto/               # *.proto (market, trading)
  Sources/…            # โค้ดและโค้ดที่ generate (เก็บใน repo)
  App/TradePulse/      # แอป iOS + project.yml + .xcodeproj
  docs/                # superpowers/specs, results
  Makefile             # bootstrap · proto · server · app · test · demo
  README.md
```

## 7. ความเสี่ยง

| ความเสี่ยง | ลดอย่างไร |
|---|---|
| ชุดเครื่องมือใหม่ (Xcode 27.2 / Swift 6.4) อาจเข้ากับ gRPC Swift 2 / Hummingbird ไม่สนิท | **งานแรกคือ walking skeleton**: ให้แอปบน Simulator คุยกับเซิร์ฟเวอร์ครบทั้ง 3 โปรโตคอลแบบเล็กที่สุดก่อนสร้างฟีเจอร์ใด ๆ |
| Swift 6 strict concurrency ขัดกับเส้นทางร้อน | เก็บเส้นทางร้อนไว้ในส่วนเล็ก ๆ ที่เทสต์หนัก แยกจาก UI |
| loopback ทำให้ latency ดูดีเกินจริง | โปรไฟล์ใส่ latency/jitter + เขียนข้อจำกัดใน README ตรง ๆ |
| ขอบเขตบานปลาย (ความสมจริงของ matching, ฟีเจอร์กราฟ) | ยึดเกณฑ์เดโม 2 นาทีในข้อ 3; อย่างอื่นเป็นรายการเสริมหลังผ่าน |
| ต้องติดตั้ง `xcodegen` ผ่าน Homebrew; `protoc` รอบแรกคอมไพล์นาน | ขออนุญาตก่อนติดตั้ง; เก็บโค้ด generated + `.xcodeproj` ไว้ใน repo เพื่อให้คนโคลนไม่ต้องทำซ้ำ |

## 8. สิ่งที่ปล่อยให้ผู้สร้างตัดสินใจ

โครงไฟล์ละเอียด · เวอร์ชันไลบรารี (ตรึงตอนสร้าง) · พารามิเตอร์จำลอง (ความผันผวน สเปรด ความลึก) · ชุดหุ้นและราคาอ้างอิง · สี/ฟอนต์/การจัดวาง (ชัด อ่านง่าย รองรับโหมดมืด ไม่ใช้แบรนด์ใคร) · คำสั่งเทสต์ละเอียด · ถ้อยคำ README · การเปลี่ยนไปใช้ Metal หรือแพ็กไบนารีเองหากการวัดชี้ว่าจำเป็น

## 9. การตัดสินใจของผมที่ขอให้ตรวจ

1. ทาง ก (Swift ทั้งสแตก) และโครง Hummingbird + gRPC Swift 2 ใน process เดียว
2. กราฟด้วย `Canvas` ไม่ใช่ Swift Charts/Metal
3. อัปเดตตลาดเป็น "สถานะล่าสุด" ที่ conflate ได้ + แท่งเทียนปัจจุบันรวมที่ server
4. คำสั่ง/ธุรกรรมแบบ event-sourced มี `event_seq` + `server_epoch` + idempotency
5. รอบแรกไม่มี TLS / certificate pinning / Face ID / auth
6. iOS 18+ บน Simulator เป็นเป้าหมาย ไม่รับรองเครื่องจริง
7. ข้อมูลทั้งหมดเป็นของจำลอง มีป้าย "SIMULATED DATA" ไม่ใช้แบรนด์ Kasikorn
8. UI ภาษาอังกฤษ ชื่อบริษัทแสดงเป็นภาษาไทย
9. เก็บโค้ด generated และ `.xcodeproj` ใน repo; ยังไม่ commit อะไรจนกว่าคุณสั่ง
