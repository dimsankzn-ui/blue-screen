package local.bluescreen.tv;
import java.io.*;
import java.nio.charset.StandardCharsets;

public final class WireChecks {
    public static void main(String[] args) throws Exception {
        if (!Wire.authenticate(input("BLUSCR02123456".getBytes(StandardCharsets.US_ASCII)), "123456")) throw new AssertionError();
        if (Wire.authenticate(input("BLUSCR02000000".getBytes(StandardCharsets.US_ASCII)), "123456")) throw new AssertionError();
        if (Wire.authenticate(input("INVALID1123456".getBytes(StandardCharsets.US_ASCII)), "123456")) throw new AssertionError();
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
    static DataInputStream input(byte[] data) { return new DataInputStream(new ByteArrayInputStream(data)); }
    static byte[] packet(int length) throws Exception {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        new DataOutputStream(buffer).writeInt(length);
        return buffer.toByteArray();
    }
}
