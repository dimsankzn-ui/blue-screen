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
        final String codec;
        Mode(int w,int h,int f,int id,String c) { width=w; height=h; fpsMilli=f; nativeID=id; codec=c; }
    }
    final List<Mode> modes = new ArrayList<>();
    final int physicalWidth, physicalHeight;
    DisplayCapabilities(Display display) {
        int[] physical = physicalSize(display);
        physicalWidth=physical[0]; physicalHeight=physical[1];
        Display.Mode current = display.getMode();
        for (Display.Mode mode : display.getSupportedModes()) {
            boolean currentSize = mode.getPhysicalWidth()==current.getPhysicalWidth() && mode.getPhysicalHeight()==current.getPhysicalHeight();
            int width=currentSize ? physicalWidth : mode.getPhysicalWidth();
            int height=currentSize ? physicalHeight : mode.getPhysicalHeight();
            int fps=Math.round(mode.getRefreshRate()*1000);
            add(width,height,fps,mode.getModeId());
            for (int[] size : new int[][]{{2560,1440},{1920,1080},{1600,900},{1280,720}})
                if (size[0]<=width && size[1]<=height && Math.abs(width/(double)height-size[0]/(double)size[1])<0.02)
                    add(size[0],size[1],fps,mode.getModeId());
        }
    }
    // Same vendor-size workaround used by AndroidX DisplayCompat: UI size is not panel size on TV.
    private static int[] physicalSize(Display display) {
        Display.Mode current=display.getMode();
        int[] fallback={current.getPhysicalWidth(),current.getPhysicalHeight()};
        if (display.getDisplayId()!=Display.DEFAULT_DISPLAY) return fallback;
        try {
            String value=(String)Class.forName("android.os.SystemProperties").getMethod("get",String.class).invoke(null,"vendor.display-size");
            return parseSize(value,fallback);
        } catch (Exception ignored) { return fallback; }
    }
    static int[] parseSize(String value,int[] fallback) {
        try {
            String[] parts=value.trim().split("x");
            if(parts.length!=2) return fallback;
            int w=Integer.parseInt(parts[0]),h=Integer.parseInt(parts[1]);
            if(w<640 || w>3840 || h<360 || h>2160 || w%2!=0 || h%2!=0) return fallback;
            return new int[]{w,h};
        } catch(Exception ignored) { return fallback; }
    }
    private void add(int w,int h,int f,int id) {
        if(w<640 || w>3840 || h<360 || h>2160 || w%2!=0 || h%2!=0 || f<15000 || f>120000 || find(w,h,f)!=null) return;
        String[] order=w>1920 || h>1080 ? new String[]{"hevc","h264"} : new String[]{"h264","hevc"};
        for(String codec:order) if(supported(w,h,f,codec)) { modes.add(new Mode(w,h,f,id,codec));return; }
    }
    private static boolean supported(int w,int h,int f,String codec) {
        String mime=codec.equals("hevc") ? "video/hevc" : "video/avc";
        for(MediaCodecInfo info:new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
            if(info.isEncoder() || !info.isHardwareAccelerated()) continue;
            for(String type:info.getSupportedTypes()) if(type.equalsIgnoreCase(mime)) {
                try { if(info.getCapabilitiesForType(type).getVideoCapabilities().areSizeAndRateSupported(w,h,Math.ceil(f/1000.0))) return true; }
                catch(RuntimeException ignored) {}
            }
        }
        return false;
    }
    Mode find(int w,int h,int f) { for(Mode m:modes) if(m.width==w && m.height==h && m.fpsMilli==f)return m;return null; }
    byte[] json() throws Exception {
        JSONArray values=new JSONArray();
        for(Mode m:modes) values.put(new JSONObject().put("width",m.width).put("height",m.height).put("fpsMilli",m.fpsMilli).put("codec",m.codec));
        return new JSONObject().put("protocolVersion",5).put("physicalWidth",physicalWidth).put("physicalHeight",physicalHeight).put("modes",values).toString().getBytes(StandardCharsets.UTF_8);
    }
}
