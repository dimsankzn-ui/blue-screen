package local.bluescreen.tv;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.Surface;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

final class VideoDecoder implements AutoCloseable {
    private final MediaCodec codec;
    private final HandlerThread metrics = new HandlerThread("BlueScreen-rendered");
    private final Thread drain;
    private volatile boolean running = true;
    private volatile Exception failure;
    volatile int accepted, rendered, fpsMilli;
    private final ArrayDeque<Long> presentations = new ArrayDeque<>();
    private long loggedAt;

    VideoDecoder(int width, int height, int fps, byte[] configuration, Surface surface) throws Exception {
        MediaCodecInfo chosen = null;
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
            if (info.isEncoder() || !info.isHardwareAccelerated()) continue;
            for (String type : info.getSupportedTypes()) {
                if (!"video/avc".equalsIgnoreCase(type)) continue;
                MediaCodecInfo.CodecCapabilities caps = info.getCapabilitiesForType(type);
                if (caps.getVideoCapabilities().areSizeAndRateSupported(width, height, fps)) { chosen = info; break; }
            }
            if (chosen != null) break;
        }
        if (chosen == null) throw new IOException("Нет аппаратного H.264-декодера для 1920×1080 / 60");
        List<byte[]> parameters = splitParameters(configuration);
        if (parameters.size() != 2 || (parameters.get(0)[4] & 31) != 7 || (parameters.get(1)[4] & 31) != 8)
            throw new IOException("Неверные параметры H.264");
        MediaFormat format = MediaFormat.createVideoFormat("video/avc", width, height);
        format.setByteBuffer("csd-0", ByteBuffer.wrap(parameters.get(0)));
        format.setByteBuffer("csd-1", ByteBuffer.wrap(parameters.get(1)));
        format.setInteger(MediaFormat.KEY_FRAME_RATE, fps);
        format.setFloat(MediaFormat.KEY_OPERATING_RATE, fps);
        format.setInteger(MediaFormat.KEY_PRIORITY, 0);
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, Wire.MAX_FRAME);
        if (chosen.getCapabilitiesForType("video/avc").isFeatureSupported("low-latency")) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
        codec = MediaCodec.createByCodecName(chosen.getName());
        try {
            codec.configure(format, surface, null, 0);
            metrics.start();
            codec.setOnFrameRenderedListener((ignored, timeUs, nanoTime) -> {
                if (!running || nanoTime <= 0) return;
                rendered++;
                presentations.addLast(nanoTime);
                while (presentations.size() > 2 && nanoTime - presentations.peekFirst() > 2_000_000_000L) presentations.removeFirst();
                if (presentations.size() > 1 && nanoTime > presentations.peekFirst())
                    fpsMilli = (int) Math.round((presentations.size() - 1) * 1_000_000_000_000.0 / (nanoTime - presentations.peekFirst()));
                if (nanoTime - loggedAt >= 5_000_000_000L) {
                    loggedAt = nanoTime;
                    android.util.Log.i("BlueScreen", String.format(Locale.US, "RENDER_METRICS accepted=%d rendered=%d fps=%.3f", accepted, rendered, fpsMilli / 1000.0));
                }
            }, new Handler(metrics.getLooper()));
            codec.start();
        } catch (Exception error) { codec.release(); metrics.quitSafely(); throw error; }
        android.util.Log.i("BlueScreen", "HARDWARE_DECODER " + chosen.getName() + " " + width + "x" + height + " target=" + fps);
        drain = new Thread(() -> {
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            try {
                while (running) {
                    int index = codec.dequeueOutputBuffer(info, 10000);
                    if (index >= 0) codec.releaseOutputBuffer(index, true);
                    else if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) android.util.Log.i("BlueScreen", "VIDEO_FORMAT " + codec.getOutputFormat());
                }
            } catch (Exception error) { if (running) failure = error; }
        }, "BlueScreen-video-output");
        drain.start();
    }

    void queue(byte[] data, long presentationUs) throws Exception {
        long deadline = System.nanoTime() + 2_000_000_000L;
        while (running && failure == null && System.nanoTime() < deadline) {
            int index = codec.dequeueInputBuffer(10000);
            if (index < 0) continue;
            ByteBuffer buffer = codec.getInputBuffer(index);
            if (buffer == null || buffer.capacity() < data.length) throw new IOException("Видеопакет не помещается в декодер");
            buffer.clear();
            buffer.put(data);
            codec.queueInputBuffer(index, 0, data.length, presentationUs, 0);
            accepted++;
            return;
        }
        throw new IOException("Декодер перестал принимать видео", failure);
    }

    @Override public void close() {
        running = false;
        try { drain.join(1500); } catch (InterruptedException error) { Thread.currentThread().interrupt(); }
        try { codec.stop(); } catch (Exception ignored) {}
        codec.release();
        metrics.quitSafely();
    }

    private static List<byte[]> splitParameters(byte[] bytes) throws IOException {
        ArrayList<Integer> starts = new ArrayList<>();
        for (int i = 0; i + 4 < bytes.length; i++)
            if (bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1) { starts.add(i); i += 3; }
        if (starts.isEmpty() || starts.get(0) != 0) throw new IOException("Нет параметров видеопотока");
        ArrayList<byte[]> values = new ArrayList<>();
        for (int i = 0; i < starts.size(); i++) values.add(Arrays.copyOfRange(bytes, starts.get(i), i + 1 < starts.size() ? starts.get(i+1) : bytes.length));
        return values;
    }
}
