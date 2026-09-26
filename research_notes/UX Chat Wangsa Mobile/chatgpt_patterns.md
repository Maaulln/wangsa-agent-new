# Official ChatGPT Mobile UX Patterns

## Bagaimana pencarian dan aktivitas agen sebaiknya terlihat?

### Takeaway
Jadikan progres mudah dipahami, dapat dibuka untuk detail, dan dapat dihentikan atau diarahkan ulang. Pisahkan jejak aktivitas dari daftar sumber hasil: keduanya menjawab pertanyaan pengguna yang berbeda ("apa yang sedang dilakukan?" vs. "informasi ini bersumber dari mana?").

### Cited Findings
- ChatGPT Search dapat berjalan otomatis ketika pertanyaan cocok untuk informasi terkini; pengguna juga dapat mengaktifkan Search secara eksplisit melalui menu tools atau `/`. Respons dapat berisi sitasi yang bisa diketuk, serta bagian Sources berisi sumber terkait. — [Searching the web with ChatGPT](https://help.openai.com/en/articles/9237897-searching-the-web-with-chatgpt)
- Untuk Deep Research, pengguna dapat melihat progres secara real-time, menginterupsi tugas untuk mengubah fokus, dan memperbarui sumber yang boleh diakses. Laporan akhir memiliki sitasi/tautan sumber serta riwayat aktivitas. — [Deep research in ChatGPT](https://help.openai.com/en/articles/10500283-deep-research-in-chatgpt)
- OpenAI menjelaskan bahwa tampilan Deep Research menyajikan ringkasan langkah dan sumber yang dipakai selama tugas berjalan. — [Introducing deep research](https://openai.com/index/introducing-deep-research/)
- Android ChatGPT mendukung aksi jawaban seperti Copy, feedback positif/negatif, Read aloud, Share, dan Try again; aksi dapat muncul di bawah jawaban atau menu tiga titik. — [ChatGPT Android App FAQ](https://help.openai.com/en/articles/8142208-chatgpt-android-app-faq)
- Di Wangsa sekarang sudah ada `ToolCallCard` yang memetakan tool menjadi label ringkas dan dapat membuka preview; `SourceChips` mengambil metadata sumber atau tautan Markdown (maksimal lima); indikator streaming dan tombol stop sudah ada. Implementasi terkait: `apps/mobile/lib/chat/view/widgets/tool_call_card.dart`, `apps/mobile/lib/chat/view/widgets/source_chips.dart`, dan `apps/mobile/lib/chat/view/chat_page.dart`.

### Inferences
- Peningkatan yang paling relevan bukan menambah label tool lagi, melainkan membuat progres tool terasa kronologis dan hidup ketika tiap tool mulai/selesai: satu baris status kompak seperti “Mencari di web…” → “Membuka 3 halaman” → “Menyusun jawaban”, dengan state aktif/selesai/gagal dan ekspansi untuk detail. Tampilkan hanya langkah yang benar-benar dilaporkan backend; jangan mengarang status.
- Pertahankan dua lapisan informasi: indikator aktivitas selama proses dan sumber yang dapat diketuk pada jawaban. Sumber idealnya memakai favicon/domain, judul pendek, dan jumlah; tap membuka lembar Sources yang berisi domain, judul, tanggal bila tersedia, dan tautan. Inline citations sebaiknya terkait klaim bila backend menyediakan pemetaan; jangan menebak relasi klaim-ke-sumber dari sekadar URL.
- Satukan kontrol stop dan status dalam composer: saat menunggu, tombol kirim berubah menjadi Stop yang jelas; setelah selesai, sediakan Try again/regenerate dan Edit prompt di menu pesan. Android FAQ menunjukkan pola aksi kontekstual tersebut, tetapi tidak menjelaskan seluruh detail perilaku visual atau posisi tetapnya.
- Karena sumber web bisa keliru/usang, tampilkan provenance dan beri akses satu ketuk ke sumber asal, bukan menyajikan chip semata sebagai dekorasi. OpenAI sendiri mengingatkan bahwa hasil/sitasi dapat tidak lengkap atau salah dan menyarankan membuka sumber untuk verifikasi.

### Gaps
- Dokumentasi bantuan resmi menjelaskan kemampuan dan titik kontrol ChatGPT, tetapi tidak mendokumentasikan secara menyeluruh microcopy, animasi, atau perilaku loading pada UI mobile saat ini. Rekomendasi detail visual di atas adalah inferensi desain, bukan klaim bahwa ChatGPT selalu menampilkan tahapan yang sama.
- Backend Wangsa yang sekarang perlu diperiksa terpisah untuk memastikan event `tool.start/progress/complete` dapat menyuplai judul situs, tahap aktivitas, serta status yang cukup real-time.

## Apa pola yang relevan untuk aksi pesan dan file?

### Takeaway
Sediakan tindakan yang paling sering dipakai langsung di bawah jawaban, simpan tindakan sekunder dalam menu, dan buat lampiran tampak jelas sebelum dikirim serta sesudah diproses.

### Cited Findings
- Pada Android, ChatGPT menyebut Copy, Good response, Bad response, Read aloud, Share, dan Try again sebagai contoh aksi respons; ketersediaan bergantung pada konteks. Pengguna juga dapat menyeleksi teks dengan menekan lama respons. — [ChatGPT Android App FAQ](https://help.openai.com/en/articles/8142208-chatgpt-android-app-faq)
- ChatGPT mendukung dokumen, spreadsheet, presentasi, dan berkas lain untuk tugas seperti merangkum, membandingkan, menganalisis, dan mengekstrak informasi; unggahan tersedia di aplikasi mobile yang didukung. — [File Uploads FAQ](https://help.openai.com/en/articles/8555545-file-uploads-faq)
- Android ChatGPT punya pencarian riwayat percakapan dari sidebar. — [ChatGPT Android App FAQ](https://help.openai.com/en/articles/8142208-chatgpt-android-app-faq)
- Composer Wangsa saat ini menerima foto kamera/galeri dan mendukung beberapa gambar tertunda, tetapi tidak tampak menyediakan picker dokumen umum di `chat_page.dart`; jawaban saat ini menampilkan action row dengan copy, suka/tidak suka, bacakan, dan bagikan. Tombol suka/tidak suka masih menampilkan snackbar “belum tersedia.” Ada daftar sesi dan penghapusan sesi di sidebar. — `apps/mobile/lib/chat/view/chat_page.dart`, `apps/mobile/lib/chat/view/message_bubble.dart`.

### Inferences
- Prioritas aksi pesan: Copy sebagai ikon utama; kumpulkan feedback, Share, Read aloud, Try again, dan Edit ke baris sekunder/menu kontekstual supaya tidak membuat transcript terlalu ramai. Pastikan setiap aksi yang terlihat benar-benar bekerja; aksi placeholder yang hanya menampilkan “belum tersedia” lebih baik disembunyikan sampai fungsional.
- Tambahkan edit-and-resend untuk pesan pengguna dan regenerate untuk balasan, dengan konteks percakapan yang jelas. Keduanya mengurangi biaya memperbaiki salah ketik atau mengulang jawaban tanpa pengguna harus menyalin prompt secara manual.
- Jika kemampuan backend mendukung, perluas lampiran dari foto menjadi dokumen umum secara bertahap. Tampilkan preview berbentuk chip/kartu dengan nama, tipe, ukuran/status upload dan tombol hapus sebelum kirim; setelah dikirim, tampilkan lampiran yang sama pada bubble agar pengguna bisa memastikan file mana yang dianalisis. Ini tidak menyiratkan Wangsa sudah mendukung analisis semua format.
- Pastikan pesan panjang bisa diseleksi dan disalin sebagian, sambil mempertahankan tombol salin seluruh jawaban. Untuk daftar riwayat, pencarian percakapan akan lebih membantu daripada hanya sesi berurutan jika jumlah sesi bertambah.

### Gaps
- Sumber OpenAI menjelaskan aksi yang mungkin tersedia, namun tidak menetapkan satu tata letak aksi yang ideal untuk semua konteks. Urutan aksi untuk Wangsa perlu divalidasi dari pemakaian nyata.
- Status dukungan format file oleh backend Wangsa tidak diaudit pada sub-tugas ini; implementasi dokumen baru perlu mengecek API, batas ukuran, dan model/kapabilitas backend.

## Bagaimana suara sebaiknya menyatu dengan chat?

### Takeaway
Untuk percakapan suara, pertahankan satu riwayat teks yang bisa ditinjau, tampilkan transkrip/caption ketika sesuai, dan beri kontrol yang konsisten untuk mute, stop, serta keluar. Bedakan dikte (rekam prompt yang dapat diperiksa) dari percakapan suara langsung.

### Cited Findings
- ChatGPT Voice di mobile dapat terintegrasi di halaman chat atau memakai mode terpisah; selama sesi, ada kontrol mute/unmute dan keluar. — [Voice Mode FAQ](https://help.openai.com/en/articles/8400625-voice-mode-faq)
- ChatGPT Live memperlihatkan respons sebagai teks di chat ketika diucapkan; setelah sesi berakhir transkrip masuk ke riwayat. Pengguna dapat menampilkan caption respons pada iOS/Android yang mendukungnya. — [ChatGPT Voice](https://help.openai.com/en/articles/20001274-chatgpt-voice)
- OpenAI membedakan Voice untuk percakapan bolak-balik langsung dan Dictation untuk merekam prompt, memeriksa/mengedit transkrip, lalu mengirimnya sebagai teks. Transkrip suara tidak selalu verbatim. — [ChatGPT Voice](https://help.openai.com/en/articles/20001274-chatgpt-voice)
- Wangsa sudah memiliki tombol suara, lapisan Voice Orb, partial transcript ke draft, dan mode TTS di aksi jawaban; voice overlay menutup saat transkrip final dikirim. — `apps/mobile/lib/chat/view/chat_page.dart`, `apps/mobile/lib/chat/view/message_bubble.dart`, `apps/mobile/lib/chat/view/widgets/voice_orb.dart`.

### Inferences
- Pertahankan alur saat ini yang menempatkan voice di atas chat; tingkatkan dengan caption/transkrip yang selalu dapat ditinjau dan tombol yang eksplisit untuk kirim, batalkan, atau mulai ulang ketika menggunakan dikte. Hindari auto-send jika transkripsi parsial masih dapat diperbaiki.
- Saat TTS membacakan jawaban, ubah ikon menjadi Pause/Stop dan tampilkan state aktif. Saat voice live, tampilkan indikator mikrofon sedang mendengar, mute, dan akhiri dalam satu permukaan agar pengguna tahu status privasinya.
- Tawarkan opsi caption dan bahasa utama bila deteksi bahasa sering salah; OpenAI menyebut transkripsi suara dapat tidak persis dan menyediakan pengaturan bahasa untuk dictation.

### Gaps
- FAQ menjelaskan perbedaan mode dan kontrol, tetapi tidak membuktikan pola voice tertentu meningkatkan kenyamanan untuk semua pengguna. Keputusan tentang auto-send, overlay, dan caption perlu diuji pada pengguna Wangsa, terutama dalam kondisi bising dan aksesibilitas.
