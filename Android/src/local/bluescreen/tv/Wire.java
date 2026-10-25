package local.bluescreen.tv;

import java.io.DataInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

final class Wire {
    static final int MAX_FRAME = 2 * 1024 * 1024;
    static boolean authenticate(DataInputStream input, String pin) throws IOException {
        byte[] hello = new byte[14];
        input.readFully(hello);
        byte[] expected = ("BLUSCR02" + pin).getBytes(StandardCharsets.US_ASCII);
        return MessageDigest.isEqual(hello, expected);
    }
    static byte[] readFrame(DataInputStream input) throws IOException {
        int length = input.readInt();
        if (length < 0 || length > MAX_FRAME) throw new IOException("Недопустимый размер кадра");
        byte[] data = new byte[length];
        input.readFully(data);
        return data;
    }
}
