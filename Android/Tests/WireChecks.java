package local.bluescreen.tv;
import java.io.*;
import java.nio.charset.StandardCharsets;

public final class WireChecks {
    public static void main(String[] args) throws Exception {
        String id = "12345678-1234-1234-1234-123456789012";
        Wire.Hello first = Wire.readHello(input(hello(0, id, "123456".getBytes(StandardCharsets.US_ASCII))));
        if (!Wire.authorize(first, "123456", null)) throw new AssertionError("Valid PIN rejected");
        if (Wire.authorize(first, "654321", null)) throw new AssertionError("Bad PIN accepted");
        byte[] token = new byte[32]; new java.security.SecureRandom().nextBytes(token);
        Wire.Hello saved = Wire.readHello(input(hello(1, id, token)));
        byte[] hash = java.security.MessageDigest.getInstance("SHA-256").digest(token);
        if (!Wire.authorize(saved, "000000", hash)) throw new AssertionError("Remembered Mac rejected");
        if (Wire.authorize(saved, "000000", null)) throw new AssertionError("Unknown Mac accepted");
        byte[] badHash = hash.clone(); badHash[0] ^= 1;
        if (Wire.authorize(saved, "000000", badHash)) throw new AssertionError("Bad token accepted");
        for (byte[] invalid : new byte[][] { "BLUSCR02".getBytes(), hello(2,id,token), hello(0,"INVALID!-1234-1234-1234-123456789012",token), java.util.Arrays.copyOf(hello(1,id,token),50) }) {
            try { Wire.readHello(input(invalid)); throw new AssertionError("Invalid hello accepted"); }
            catch (IOException expected) {}
        }
        for (int size : new int[]{-1, Wire.MAX_FRAME + 1, Integer.MAX_VALUE}) {
            try { Wire.readFrame(input(packet(size))); throw new AssertionError("Accepted oversized frame"); }
            catch (IOException expected) {}
        }
        if (Wire.readFrame(input(packet(0))).length != 0) throw new AssertionError();
        try { Wire.readFrame(input(packet(10))); throw new AssertionError("Accepted truncated frame"); }
        catch (EOFException expected) {}
        byte[] valid = new byte[]{0,0,0,3,1,2,3};
        if (Wire.readFrame(input(valid)).length != 3) throw new AssertionError();
        System.out.println("PASS: authentication, bad protocol/code, heartbeat, frame bounds, truncated payload, valid frame");
    }
    static byte[] hello(int mode, String id, byte[] secret) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write("BLUSCR03".getBytes(StandardCharsets.US_ASCII)); out.write(mode);
        out.write(id.getBytes(StandardCharsets.US_ASCII)); out.write(secret); return out.toByteArray();
    }
    static DataInputStream input(byte[] data) { return new DataInputStream(new ByteArrayInputStream(data)); }
    static byte[] packet(int length) throws Exception {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        new DataOutputStream(buffer).writeInt(length);
        return buffer.toByteArray();
    }
}
