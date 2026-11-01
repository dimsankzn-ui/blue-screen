package local.bluescreen.tv;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import java.io.IOException;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;

// Audio is an independent bounded stream: slow HDMI/BT playback must not stall video.
final class AudioPlayer implements AutoCloseable {
    private static final int RATE = 48000;
    private static final int CHANNELS = 2;
    private static final int BYTES_PER_FRAME = 4;
    private final ArrayBlockingQueue<byte[]> packets = new ArrayBlockingQueue<>(20);
    private final AudioTrack track;
    private final Thread output;
    private volatile boolean running = true;
    private volatile Exception failure;
    private int playedPackets;

    AudioPlayer() throws IOException {
        int min = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT);
        if (min <= 0) throw new IOException("Аудиовыход 48 kHz stereo недоступен");
        track = new AudioTrack.Builder()
            .setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
            .setBufferSizeInBytes(Math.max(min, 38400))
            .setTransferMode(AudioTrack.MODE_STREAM).build();
        if (track.getState() != AudioTrack.STATE_INITIALIZED) {
            track.release();
            throw new IOException("AudioTrack не инициализирован");
        }
        output = new Thread(() -> {
            try {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO);
                // Prebuffer ~100ms to absorb Wi-Fi jitter before starting AudioTrack.
                // The Mac keeps its own output; only the TV's playback waits briefly.
                while (running && packets.size() < 5) Thread.sleep(5);
                if (!running) return;
                track.play();
                while (running) {
                    byte[] packet = packets.poll(100, TimeUnit.MILLISECONDS);
                    if (packet == null) continue;
                    int offset = 0;
                    while (running && offset < packet.length) {
                        int written = track.write(packet, offset, packet.length - offset,
                            AudioTrack.WRITE_BLOCKING);
                        if (written <= 0) throw new IOException("AudioTrack write: " + written);
                        offset += written;
                    }
                    if (++playedPackets == 1 || playedPackets % 250 == 0)
                        android.util.Log.i("BlueScreen", "AUDIO_PLAYED packets=" + playedPackets
                            + " underruns=" + track.getUnderrunCount() + " queued=" + packets.size());
                }
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            } catch (Exception error) {
                if (running) {
                    failure = error;
                    android.util.Log.e("BlueScreen", "AUDIO_OUTPUT_FAILED", error);
                }
            }
        }, "BlueScreen-audio-output");
        output.start();
    }

    void queue(byte[] pcm) throws IOException {
        if (failure != null) throw new IOException("Аудиовыход остановился", failure);
        if (pcm.length == 0 || pcm.length % BYTES_PER_FRAME != 0 || pcm.length > 64 * 1024)
            throw new IOException("Неверный PCM-аудиопакет");
        if (!packets.offer(pcm)) {
            packets.poll(); // No unbounded latency; discard the oldest delayed audio.
            packets.offer(pcm);
        }
    }

    @Override public void close() {
        running = false;
        output.interrupt();
        try { output.join(500); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
        try { track.pause(); track.flush(); track.stop(); } catch (Exception ignored) {}
        track.release();
    }
}
