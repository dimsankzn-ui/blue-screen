package local.bluescreen.tv;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.util.AtomicFile;
import android.util.Base64;
import java.io.File;
import java.io.FileInputStream;
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
import java.net.ServerSocket;
import java.net.Socket;
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
    private volatile ServerSocket presence;
    private volatile DisplayCapabilities capabilities;
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
        Button forget = new Button(this);
        forget.setText("Забыть все Mac");
        forget.setOnClickListener(v -> {
            getSharedPreferences("trusted-macs", MODE_PRIVATE).edit().clear().commit();
            pin = String.format(Locale.US, "%06d", random.nextInt(1000000));
            try { if (client != null) client.close(); } catch (Exception ignored) {}
            waiting(generation, "Сохранённые Mac удалены");
        });
        pairing.addView(forget);
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
        capabilities = new DisplayCapabilities(getWindowManager().getDefaultDisplay());
        new Thread(() -> servePresence(mine), "BlueScreen-presence").start();
        new Thread(() -> serve(mine), "BlueScreen-receiver").start();
    }
    @Override public void onStop() {
        generation++;
        closeSockets();
        super.onStop();
    }
    private void closeSockets() {
        try { if (presence != null) presence.close(); } catch (Exception ignored) {}
        try { if (client != null) client.close(); } catch (Exception ignored) {}
        try { if (listener != null) listener.close(); } catch (Exception ignored) {}
    }

    private KeyStore identity() throws Exception {
        File persisted = new File(getNoBackupFilesDir(), "receiver-identity.p12");
        if (persisted.exists()) {
            KeyStore saved = KeyStore.getInstance("PKCS12");
            try (FileInputStream file = new AtomicFile(persisted).openRead()) { saved.load(file, new char[0]); }
            return saved;
        }
        KeyStore keys = KeyStore.getInstance("AndroidKeyStore");
        keys.load(null);
        String alias = "bluescreen-receiver-rsa-v2";
        try {
        if (getSharedPreferences("identity", MODE_PRIVATE).getBoolean("software-tls", false))
            throw new java.security.ProviderException("Hardware key cannot serve TLS on this firmware");
        if (!keys.containsAlias(alias)) {
            KeyPairGenerator generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore");
            generator.initialize(new KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY | KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(2048)
                // Conscrypt may implement TLS RSA signatures via private-key Cipher operations.
                // Authorize its required padding modes; TLS still applies its own padding/signature format.
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE, KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1)
                .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1, KeyProperties.SIGNATURE_PADDING_RSA_PSS)
                .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                .setCertificateSubject(new X500Principal("CN=BlueScreen TV"))
                .setCertificateSerialNumber(new BigInteger(120, random))
                .setCertificateNotBefore(new Date(System.currentTimeMillis() - 86400000L))
                .setCertificateNotAfter(new Date(System.currentTimeMillis() + 315360000000L)).build());
            generator.generateKeyPair();
        }
            return keys;
        } catch (java.security.GeneralSecurityException | java.security.ProviderException error) {
            android.util.Log.w("BlueScreen", "AndroidKeyStore unavailable; using app-private persistent identity");
        }
        // Fallback identity stays in Android internal no-backup storage, private to this app.
        // Persist it so an already paired Mac can verify the same TV after a restart.
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048, random);
        KeyPair pair = generator.generateKeyPair();
        BouncyCastleProvider provider = new BouncyCastleProvider();
        X500Principal subject = new X500Principal("CN=BlueScreen TV Session");
        java.security.cert.X509Certificate cert = new JcaX509CertificateConverter().setProvider(provider).getCertificate(
            new JcaX509v3CertificateBuilder(subject, new BigInteger(120, random),
                new Date(System.currentTimeMillis() - 86400000L), new Date(System.currentTimeMillis() + 315360000000L),
                subject, pair.getPublic()).build(new JcaContentSignerBuilder("SHA256withRSA").setProvider(provider).build(pair.getPrivate())));
        cert.verify(pair.getPublic());
        keys = KeyStore.getInstance("PKCS12");
        keys.load(null, new char[0]);
        keys.setKeyEntry("session", pair.getPrivate(), new char[0], new java.security.cert.Certificate[]{cert});
        AtomicFile storage = new AtomicFile(persisted);
        FileOutputStream file = storage.startWrite();
        try { keys.store(file, new char[0]); storage.finishWrite(file); }
        catch (Exception error) { storage.failWrite(file); throw error; }
        return keys;
    }

    private SSLContext createTLS() throws Exception {
        KeyStore keys = identity();
        String alias = keys.containsAlias("session") ? "session" : "bluescreen-receiver-rsa-v2";
        byte[] cert = keys.getCertificate(alias).getEncoded();
        // Public certificate only; used for exact fingerprint verification during development.
        try (FileOutputStream file = openFileOutput("receiver-cert.der", MODE_PRIVATE)) { file.write(cert); }
        StringBuilder hash = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(cert)) hash.append(String.format(Locale.US, "%02X", b & 255));
        fingerprint = hash.substring(0, 4) + "-" + hash.substring(4, 8) + "-" + hash.substring(8, 12);
        KeyManagerFactory manager = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        manager.init(keys, "AndroidKeyStore".equals(keys.getType()) ? null : new char[0]);
        SSLContext context = SSLContext.getInstance("TLS");
        javax.net.ssl.X509KeyManager delegate = null;
        for (javax.net.ssl.KeyManager candidate : manager.getKeyManagers())
            if (candidate instanceof javax.net.ssl.X509KeyManager) delegate = (javax.net.ssl.X509KeyManager)candidate;
        if (delegate == null) throw new java.security.KeyStoreException("No TLS key manager");
        final javax.net.ssl.X509KeyManager selected = delegate;
        // Never let the platform choose an old alias or a certificate different from the displayed fingerprint.
        javax.net.ssl.X509ExtendedKeyManager pinned = new javax.net.ssl.X509ExtendedKeyManager() {
            public String[] getClientAliases(String type, java.security.Principal[] issuers) { return null; }
            public String chooseClientAlias(String[] types, java.security.Principal[] issuers, Socket socket) { return null; }
            public String[] getServerAliases(String type, java.security.Principal[] issuers) { return "RSA".equals(type) ? new String[]{alias} : null; }
            public String chooseServerAlias(String type, java.security.Principal[] issuers, Socket socket) { return "RSA".equals(type) ? alias : null; }
            public String chooseEngineServerAlias(String type, java.security.Principal[] issuers, javax.net.ssl.SSLEngine engine) { return "RSA".equals(type) ? alias : null; }
            public java.security.cert.X509Certificate[] getCertificateChain(String name) { return alias.equals(name) ? selected.getCertificateChain(alias) : null; }
            public java.security.PrivateKey getPrivateKey(String name) { return alias.equals(name) ? selected.getPrivateKey(alias) : null; }
        };
        context.init(new javax.net.ssl.KeyManager[]{pinned}, null, random);
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
            state.setText(message + "\nПервый раз: введите IP и код на Mac. Потом — просто «Подключиться».\nПриёмник работает, пока открыт этот экран.");
        });
    }

    // Public, read-only local availability/mode advertisement. No pairing data or video.
    private void servePresence(int mine) {
        try (ServerSocket server = new ServerSocket(8846, 4)) {
            if (generation != mine) return;
            presence = server;
            server.setSoTimeout(1000);
            while (generation == mine) {
                try (Socket socket = server.accept()) {
                    socket.setSoTimeout(2000);
                    socket.getOutputStream().write(capabilities.json());
                    socket.getOutputStream().flush();
                } catch (java.net.SocketTimeoutException ignored) {}
            }
        } catch (Exception error) {
            if (generation == mine) android.util.Log.w("BlueScreen", "Availability service stopped", error);
        }
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
                    Wire.Hello hello = Wire.readHello(input);
                    android.content.SharedPreferences trusted = getSharedPreferences("trusted-macs", MODE_PRIVATE);
                    String encoded = trusted.getString(hello.clientID, null);
                    byte[] stored = encoded == null ? null : Base64.decode(encoded, Base64.NO_WRAP);
                    if (!Wire.authorize(hello, pin, stored)) { failures++; output.write(0); output.flush(); continue; }
                    byte[] token = hello.credential;
                    if (!hello.remembered) {
                        if (trusted.getAll().size() >= 16 && encoded == null) { output.write(0); output.flush(); continue; }
                        token = new byte[32]; random.nextBytes(token);
                        String hash = Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(token), Base64.NO_WRAP);
                        if (!trusted.edit().putString(hello.clientID, hash).commit()) throw new java.io.IOException("Не удалось запомнить Mac");
                    }
                    authenticated = true;
                    output.write(1);
                    output.write(token);
                    byte[] modes = capabilities.json();
                    output.writeInt(modes.length); output.write(modes);
                    output.flush();
                    int width = input.readInt(), height = input.readInt(), fpsMilli = input.readInt();
                    DisplayCapabilities.Mode selected = capabilities.find(width,height,fpsMilli);
                    if (selected == null) throw new java.io.IOException("Неподдерживаемый режим экрана");
                    int fps = (int)Math.ceil(fpsMilli/1000.0);
                    runOnUiThread(() -> {
                        if (generation != mine) return;
                        WindowManager.LayoutParams params = getWindow().getAttributes();
                        params.preferredDisplayModeId = selected.nativeID;
                        getWindow().setAttributes(params);
                        if (surface != null && surface.isValid()) surface.setFrameRate(fpsMilli/1000f, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE);
                    });
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
                                overlay.setVisibility(View.GONE);
                            });
                        }
                    }
                } catch (Exception error) {
                    if (generation == mine) {
                        // Some firmware generates hardware RSA keys but Conscrypt cannot use them for TLS.
                        // Retry with our existing persistent app-private identity implementation, never plaintext.
                        String reason = error.toString();
                        if (!authenticated && reason.contains("RSA routines:") &&
                            !new File(getNoBackupFilesDir(), "receiver-identity.p12").exists() &&
                            !getSharedPreferences("identity", MODE_PRIVATE).getBoolean("software-tls", false)) {
                            if (getSharedPreferences("identity", MODE_PRIVATE).edit().putBoolean("software-tls", true).commit())
                                runOnUiThread(() -> { if (generation == mine) recreate(); });
                        }
                        android.util.Log.w("BlueScreen", authenticated ? "SESSION_ENDED" : "HANDSHAKE_ENDED", error);
                        if (!authenticated) {
                            java.io.StringWriter trace = new java.io.StringWriter();
                            error.printStackTrace(new java.io.PrintWriter(trace));
                            try (FileOutputStream file = openFileOutput("last-handshake-error.txt", MODE_PRIVATE)) {
                                file.write(trace.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
                            } catch (Exception ignored) {}
                        }
                    }
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
