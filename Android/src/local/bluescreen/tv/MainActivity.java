package local.bluescreen.tv;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.view.Surface;
import android.view.SurfaceView;
import android.view.SurfaceHolder;
import java.nio.ByteBuffer;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.FileOutputStream;
import java.math.BigInteger;
import java.net.Inet4Address;
import java.net.NetworkInterface;
import java.security.KeyPairGenerator;
import java.security.KeyPair;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.Date;
import java.util.Locale;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLSocket;
import javax.security.auth.x500.X500Principal;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder;
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;

public final class MainActivity extends Activity {
    private static final int PORT = 8845;
    private final SecureRandom random = new SecureRandom();
    private volatile int generation;
    private volatile SSLServerSocket listener;
    private volatile SSLSocket client;
    private volatile String pin;
    private String fingerprint = "";
    private LinearLayout pairing;
    private volatile Surface surface;
    private TextView details, state, overlay;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON | WindowManager.LayoutParams.FLAG_FULLSCREEN);
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.rgb(5, 15, 30));
        SurfaceView video = new SurfaceView(this);
        video.getHolder().addCallback(new SurfaceHolder.Callback() {
            public void surfaceCreated(SurfaceHolder holder) { surface = holder.getSurface(); }
            public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) { surface = holder.getSurface(); }
            public void surfaceDestroyed(SurfaceHolder holder) {
                surface = null;
                try { if (client != null) client.close(); } catch (Exception ignored) {}
            }
        });
        root.addView(video, new FrameLayout.LayoutParams(-1, -1));
        pairing = new LinearLayout(this);
        pairing.setOrientation(LinearLayout.VERTICAL);
        pairing.setGravity(Gravity.CENTER);
        pairing.setPadding(40, 30, 40, 30);
        root.addView(pairing, new FrameLayout.LayoutParams(-1, -1));
        pairing.addView(label("Голубой экран TV", 36));
        pairing.addView(label("Второй экран Mac • Full HD / целевые 60 кадров в секунду", 18));
        details = label("Подготавливаю защищённое подключение…", 26);
        pairing.addView(details);
        state = label("", 18);
        pairing.addView(state);
        Button close = new Button(this);
        close.setText("Закрыть приёмник");
        close.setOnClickListener(v -> finish());
        pairing.addView(close);
        overlay = label("", 14);
        overlay.setBackgroundColor(0xA0000000);
        overlay.setPadding(16, 6, 16, 6);
        overlay.setVisibility(View.GONE);
        FrameLayout.LayoutParams badge = new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.LEFT);
        root.addView(overlay, badge);
        setContentView(root);
    }

    private TextView label(String text, int size) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextColor(Color.WHITE);
        view.setTextSize(size);
        view.setGravity(Gravity.CENTER);
        view.setPadding(10, 10, 10, 10);
        return view;
    }

    @Override public void onStart() {
        super.onStart();
        final int mine = ++generation;
        new Thread(() -> serve(mine), "BlueScreen-receiver").start();
    }
    @Override public void onStop() {
        generation++;
        closeSockets();
        super.onStop();
    }
    private void closeSockets() {
        try { if (client != null) client.close(); } catch (Exception ignored) {}
        try { if (listener != null) listener.close(); } catch (Exception ignored) {}
    }

    private KeyStore identity() throws Exception {
        KeyStore keys = KeyStore.getInstance("AndroidKeyStore");
        keys.load(null);
        String alias = "bluescreen-receiver-rsa-v1";
        try {
        if (!keys.containsAlias(alias)) {
            KeyPairGenerator generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore");
            generator.initialize(new KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY)
                .setKeySize(2048)
                .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
                .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA512)
                .setCertificateSubject(new X500Principal("CN=BlueScreen TV"))
                .setCertificateSerialNumber(new BigInteger(120, random))
                .setCertificateNotBefore(new Date(System.currentTimeMillis() - 86400000L))
                .setCertificateNotAfter(new Date(System.currentTimeMillis() + 315360000000L)).build());
            generator.generateKeyPair();
        }
            return keys;
        } catch (java.security.GeneralSecurityException | java.security.ProviderException error) {
            android.util.Log.w("BlueScreen", "AndroidKeyStore unavailable; using an ephemeral session certificate");
        }
        // Some TV firmware cannot create AndroidKeyStore keys. Keep fallback keys in
        // memory only: no shared private key in the APK and no private key on disk.
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048, random);
        KeyPair pair = generator.generateKeyPair();
        BouncyCastleProvider provider = new BouncyCastleProvider();
        X500Principal subject = new X500Principal("CN=BlueScreen TV Session");
        java.security.cert.X509Certificate cert = new JcaX509CertificateConverter().setProvider(provider).getCertificate(
            new JcaX509v3CertificateBuilder(subject, new BigInteger(120, random),
                new Date(System.currentTimeMillis() - 86400000L), new Date(System.currentTimeMillis() + 86400000L),
                subject, pair.getPublic()).build(new JcaContentSignerBuilder("SHA256withRSA").setProvider(provider).build(pair.getPrivate())));
        cert.verify(pair.getPublic());
        keys = KeyStore.getInstance("PKCS12");
        keys.load(null, new char[0]);
        keys.setKeyEntry("session", pair.getPrivate(), new char[0], new java.security.cert.Certificate[]{cert});
        return keys;
    }

    private SSLContext createTLS() throws Exception {
        KeyStore keys = identity();
        String alias = keys.containsAlias("session") ? "session" : "bluescreen-receiver-rsa-v1";
        byte[] cert = keys.getCertificate(alias).getEncoded();
        // Public certificate only; used for exact fingerprint verification during development.
        try (FileOutputStream file = openFileOutput("receiver-cert.der", MODE_PRIVATE)) { file.write(cert); }
        StringBuilder hash = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(cert)) hash.append(String.format(Locale.US, "%02X", b & 255));
        fingerprint = hash.substring(0, 4) + "-" + hash.substring(4, 8) + "-" + hash.substring(8, 12);
        KeyManagerFactory manager = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        manager.init(keys, "AndroidKeyStore".equals(keys.getType()) ? null : new char[0]);
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(manager.getKeyManagers(), null, random);
        return context;
    }

    private String addresses() {
        StringBuilder text = new StringBuilder();
        try {
            for (NetworkInterface network : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!network.isUp() || network.isLoopback()) continue;
                for (java.net.InetAddress address : Collections.list(network.getInetAddresses())) {
                    if (address instanceof Inet4Address && address.isSiteLocalAddress()) text.append(address.getHostAddress()).append("  ");
                }
            }
        } catch (Exception ignored) {}
        return text.length() == 0 ? "Проверьте подключение к Wi-Fi" : text.toString().trim();
    }

    private void waiting(int mine, String message) {
        runOnUiThread(() -> {
            if (generation != mine) return;
            pairing.setVisibility(View.VISIBLE);
            overlay.setVisibility(View.GONE);
            details.setText("IP: " + addresses() + "\nКод: " + pin + "\nУстройство: " + fingerprint);
            state.setText(message + "\nНа Mac сверьте номер устройства, затем введите код.\nПриёмник работает только пока открыт этот экран.");
        });
    }

    private void serve(int mine) {
        SSLServerSocket server = null;
        try {
            SSLContext context = createTLS();
            pin = String.format(Locale.US, "%06d", random.nextInt(1000000));
            server = (SSLServerSocket) context.getServerSocketFactory().createServerSocket(PORT, 2);
            server.setEnabledProtocols(new String[]{"TLSv1.2"});
            if (generation != mine) return;
            listener = server;
            waiting(mine, "Готов к подключению");
            android.util.Log.i("BlueScreen", "LISTENING TLSv1.2 port=" + PORT);
            int failures = 0;
            long window = System.currentTimeMillis();
            while (generation == mine) {
                boolean authenticated = false;
                VideoDecoder decoder = null;
                try (SSLSocket socket = (SSLSocket) server.accept()) {
                    client = socket;
                    socket.setSoTimeout(8000);
                    socket.setTcpNoDelay(true);
                    socket.startHandshake();
                    if (System.currentTimeMillis() - window > 60000) { failures = 0; window = System.currentTimeMillis(); }
                    if (failures >= 3) continue;
                    DataInputStream input = new DataInputStream(socket.getInputStream());
                    DataOutputStream output = new DataOutputStream(socket.getOutputStream());
                    if (!Wire.authenticate(input, pin)) { failures++; output.write(0); output.flush(); continue; }
                    authenticated = true;
                    output.write(1);
                    output.flush();
                    int width = input.readInt(), height = input.readInt(), fps = input.readInt();
                    if (width != 1920 || height != 1080 || fps != 60) throw new java.io.IOException("Несовместимый формат видео");
                    socket.setSoTimeout(15000);
                    long updated = 0;
                    while (generation == mine) {
                        byte[] data = Wire.readFrame(input);
                        if (data.length > 0) {
                            if (data.length <= 9) throw new java.io.IOException("Оборван заголовок видео");
                            int kind = data[0] & 255;
                            long timeUs = ByteBuffer.wrap(data, 1, 8).getLong();
                            if (timeUs < 0) throw new java.io.IOException("Неверное время кадра");
                            byte[] payload = java.util.Arrays.copyOfRange(data, 9, data.length);
                            if (kind == 1) {
                                if (decoder == null) {
                                    long deadline = System.nanoTime() + 2_000_000_000L;
                                    while ((surface == null || !surface.isValid()) && System.nanoTime() < deadline) Thread.sleep(10);
                                    if (surface == null || !surface.isValid()) throw new java.io.IOException("Экран TV недоступен");
                                    decoder = new VideoDecoder(width, height, fps, payload, surface);
                                }
                            } else if (kind == 2 && decoder != null) {
                                decoder.queue(payload, timeUs);
                            } else throw new java.io.IOException("Неверный порядок видеопакетов");
                        }
                        int accepted = decoder == null ? 0 : decoder.accepted;
                        int rendered = decoder == null ? 0 : decoder.rendered;
                        int measured = decoder == null ? 0 : decoder.fpsMilli;
                        output.writeInt(accepted);
                        output.writeInt(rendered);
                        output.writeInt(measured);
                        output.flush();
                        if (decoder != null && System.currentTimeMillis() - updated >= 1000) {
                            updated = System.currentTimeMillis();
                            final String text = String.format(Locale.US, "BlueScreen • %d × %d • показано: %d • %.2f кадра/с • без звука", width, height, rendered, measured / 1000.0);
                            runOnUiThread(() -> {
                                if (generation != mine) return;
                                pairing.setVisibility(View.GONE);
                                overlay.setText(text);
                                overlay.setVisibility(View.VISIBLE);
                            });
                        }
                    }
                } catch (Exception error) {
                    if (generation == mine && authenticated) android.util.Log.e("BlueScreen", "SESSION_ENDED " + error.getClass().getSimpleName(), error);
                } finally {
                    if (decoder != null) decoder.close();
                    client = null;
                    if (authenticated) pin = String.format(Locale.US, "%06d", random.nextInt(1000000));
                    if (generation == mine) waiting(mine, "Готов к подключению");
                }
            }
        } catch (Exception error) {
            final String message = "Не удалось запустить приёмник: " + error.getClass().getSimpleName();
            android.util.Log.e("BlueScreen", message, error);
            runOnUiThread(() -> { if (generation == mine) state.setText(message); });
        } finally {
            try { if (server != null) server.close(); } catch (Exception ignored) {}
        }
    }
}
