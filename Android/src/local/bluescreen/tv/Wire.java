package local.bluescreen.tv;

import java.io.DataInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

final class Wire {
    static final int MAX_FRAME = 2 * 1024 * 1024;
    static final class Hello {
        final String clientID;
        final boolean remembered;
        final byte[] credential;
        Hello(String id, boolean saved, byte[] data) { clientID = id; remembered = saved; credential = data; }
    }
    static Hello readHello(DataInputStream input) throws IOException {
        byte[] magic = new byte[8]; input.readFully(magic);
        if (!MessageDigest.isEqual(magic, "BLUSCR04".getBytes(StandardCharsets.US_ASCII))) throw new IOException("Обновите приложение на Mac");
        int mode = input.readUnsignedByte();
        if (mode != 0 && mode != 1) throw new IOException("Неверный тип подключения");
        byte[] id = new byte[36]; input.readFully(id);
        String clientID = new String(id, StandardCharsets.US_ASCII);
        if (!clientID.matches("[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}")) throw new IOException("Неверный идентификатор Mac");
        byte[] credential = new byte[mode == 0 ? 6 : 32]; input.readFully(credential);
        return new Hello(clientID, mode == 1, credential);
    }
    static boolean authorize(Hello hello, String pin, byte[] storedHash) throws java.security.GeneralSecurityException {
        if (!hello.remembered) return MessageDigest.isEqual(hello.credential, pin.getBytes(StandardCharsets.US_ASCII));
        return storedHash != null && storedHash.length == 32 && MessageDigest.isEqual(storedHash, MessageDigest.getInstance("SHA-256").digest(hello.credential));
    }
    static byte[] readFrame(DataInputStream input) throws IOException {
        int length = input.readInt();
        if (length < 0 || length > MAX_FRAME) throw new IOException("Недопустимый размер кадра");
        byte[] data = new byte[length]; input.readFully(data); return data;
    }
}
