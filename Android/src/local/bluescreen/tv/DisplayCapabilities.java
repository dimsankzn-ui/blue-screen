package local.bluescreen.tv;

import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.view.Display;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.List;
import java.nio.charset.StandardCharsets;

final class DisplayCapabilities {
    static final class Mode {
        final int width, height, fpsMilli, nativeID;
        Mode(int w, int h, int f, int id) { width=w; height=h; fpsMilli=f; nativeID=id; }
    }
    final List<Mode> modes = new ArrayList<>();
    DisplayCapabilities(Display display) {
        for (Display.Mode mode : display.getSupportedModes()) {
            int fps = Math.round(mode.getRefreshRate()*1000);
            add(mode.getPhysicalWidth(), mode.getPhysicalHeight(), fps, mode.getModeId());
            if (mode.getPhysicalWidth() >= 1920 && mode.getPhysicalHeight() >= 1080) add(1920,1080,fps,mode.getModeId());
            if (mode.getPhysicalWidth() >= 1280 && mode.getPhysicalHeight() >= 720) add(1280,720,fps,mode.getModeId());
        }
    }
    private void add(int width, int height, int fps, int nativeID) {
        if (width < 640 || width > 3840 || height < 360 || height > 2160 || width%2!=0 || height%2!=0 || fps<15000 || fps>120000) return;
        if (find(width,height,fps)!=null) return;
        for (MediaCodecInfo codec : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
            if (codec.isEncoder() || !codec.isHardwareAccelerated()) continue;
            for (String type : codec.getSupportedTypes()) {
                if (!type.equalsIgnoreCase("video/avc")) continue;
                try {
                    if (codec.getCapabilitiesForType(type).getVideoCapabilities().areSizeAndRateSupported(width,height,Math.ceil(fps/1000.0))) {
                        modes.add(new Mode(width,height,fps,nativeID)); return;
                    }
                } catch (RuntimeException ignored) {}
            }
        }
    }
    Mode find(int w, int h, int f) {
        for (Mode m:modes) if(m.width==w && m.height==h && m.fpsMilli==f) return m;
        return null;
    }
    byte[] json() throws Exception {
        JSONArray values = new JSONArray();
        for (Mode mode:modes) values.put(new JSONObject().put("width",mode.width).put("height",mode.height).put("fpsMilli",mode.fpsMilli));
        return new JSONObject().put("protocolVersion",4).put("modes",values).toString().getBytes(StandardCharsets.UTF_8);
    }
}
