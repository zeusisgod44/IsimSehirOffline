# İsim Şehir — çevrimdışı takım oyunu

Android ve iOS için Flutter ile hazırlanmış, sunucusuz yerel ağ oyunu. Oda sahibi olan telefon küçük bir WebSocket sunucusu çalıştırır. Odadaki başka telefona veya buluta bağlantı kurulmaz; oyun internet olmadan aynı Wi‑Fi ya da kişisel erişim noktası üzerinden oynanır.

## Oynama

1. Telefonları aynı Wi‑Fi ağına veya bir telefonun hotspotuna bağlayın. Hotspot kuran telefon oyunu açıp **Oda kur** seçebilir.
2. Diğer oyuncular **Yakındaki odaya katıl** ile Bonjour/mDNS keşfini kullanır. Keşif çalışmazsa oda sahibinin ekranda gördüğü IP adresini elle yazabilirler.
3. En az iki kişi bağlanınca oda sahibi oyunu başlatır. Herkes aynı Türkçe harfi ve 60 saniyelik süreyi görür.
4. Cevaplar gönderilince oyuncular başkalarının cevaplarını oylayabilir. Oylama anonimdir; cevabı yazan kişi kendi cevabına oy veremez. Katı çoğunluk kabul eder, eşitlik ret sayılır; oy vermeyenler süre sonunda evet sayılmaz.
5. Kabul edilmiş ve tekil cevap 10; aynı kategori ve aynı normalleştirilmiş cevap tekrar edilmişse 5 puandır. Boş, yanlış harfle başlayan veya reddedilen cevap 0 puan getirir.

Oda sahibi telefonu oyunun yetkili kaynağıdır. Süre, tur geçişleri ve puanlar yalnızca bu telefonda hesaplanır. Oda sahibinin uygulaması kapanırsa oyun devam edemez. Oyuncu ağdan düşerse 45 saniye yeniden katılma süresi vardır; oyuncu aynı cihazda uygulamayı tekrar açıp aynı adı kullanarak aynı ağ IP'sine bağlandığında saklanan cihaz kimliğiyle koltuğunu alır.

## Geliştirme

Gerekli araçlar: Flutter 3.47.5 veya üzeri (Dart 3.8+), Android için Android SDK ve JDK 17+, iOS derlemesi/imzası için macOS ve Xcode.

GitHub Actions çıktısı `isim-sehir-flutter-android-ios-projects` dosyası, Flutter tarafından üretilmiş tam `android/` ve `ios/` dizinlerini içerir. İmzalı iOS uygulaması hazırlamak için bu dizinleri `flutter_app/` içine koyup macOS'ta Xcode ile açın.

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

Android paketleri:

```sh
flutter build apk --release
flutter build appbundle --release
```

İmzalı dağıtım için kendi Android upload keystore'unuzu oluşturun ve `android/key.properties.example` yönergesini izleyerek gizli değerleri yalnızca yerel `android/key.properties` dosyasında tutun. Bu örnek proje imza anahtarı içermez.

## iOS kurulum ve imzalama

`ios/Runner.xcworkspace` dosyasını macOS'ta Xcode ile açın, Runner için Apple Developer Team ve Bundle Identifier seçin, ardından **Product → Archive** kullanın veya `flutter build ipa --release` çalıştırın. iOS uygulamasının cihaza yüklenebilir/dağıtılabilir IPA olması Apple geliştirici imzası gerektirir; App Store veya TestFlight dağıtımında Apple hesabı ve ilgili sertifika/provisioning profili gerekir. Bu Windows çalışma ortamında Xcode çalışmadığı için iOS derlemesi ya da imzalı IPA üretilemez.

## Yerel ağ izinleri

- iOS'ta ilk Bonjour taramasında Yerel Ağ izni verilmeli. Bu izin, `Runner/Info.plist` içine eklenen `_isimsehir._tcp` Bonjour hizmeti ve açıklamayla beyan edilir.
- Android manifesti internet soketi (yalnızca LAN), ağ durumu ve Wi‑Fi multicast kilidi izinlerini taşır. Oyun verisi hiçbir uzak adrese gönderilmez.
- Bazı misafir Wi‑Fi ağları veya otel/router ayarları cihazlar arası bağlantıyı kapatır. Bu durumda bir telefonda hotspot açıp diğerlerini ona bağlayın; yine çalışmazsa IP ile katılmayı deneyin.

## Sınırlar

Bu ilk sürüm internet eşleşmesi, hesap, merkezi sunucu veya kalıcı lider tablosu içermez. IP adresleri cihazların yerel ağ ayarlarına göre değişebilir. Otomatik keşif desteklenmezse manuel IP alanı yedek yoldur.
