package local.bluescreen.tv;

import android.app.Activity;
import android.os.Bundle;
import android.os.IBinder;
import android.content.Intent;
import android.content.ComponentName;
import android.content.ServiceConnection;
import android.graphics.Color;
import android.view.*;
import android.widget.*;

public final class MainActivity extends Activity {
    private ReceiverService receiver;
    private boolean bound;
    private LinearLayout pairing;
    private TextView details,state;
    private SurfaceView video;
    private final ServiceConnection connection=new ServiceConnection() {
        public void onServiceConnected(ComponentName name,IBinder binder) {
            receiver=((ReceiverService.LocalBinder)binder).service();bound=true;
            receiver.attach(MainActivity.this);
            Surface surface=video.getHolder().getSurface();
            if(surface!=null && surface.isValid())receiver.surface=surface;
        }
        public void onServiceDisconnected(ComponentName name) { receiver=null;bound=false; }
    };
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        setTurnScreenOn(true);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON | WindowManager.LayoutParams.FLAG_FULLSCREEN);
        FrameLayout root=new FrameLayout(this);root.setBackgroundColor(Color.rgb(5,15,30));
        video=new SurfaceView(this);
        video.getHolder().addCallback(new SurfaceHolder.Callback() {
            public void surfaceCreated(SurfaceHolder holder) { if(receiver!=null)receiver.surface=holder.getSurface(); }
            public void surfaceChanged(SurfaceHolder holder,int format,int width,int height) { if(receiver!=null)receiver.surface=holder.getSurface(); }
            public void surfaceDestroyed(SurfaceHolder holder) { if(receiver!=null)receiver.surface=null; }
        });
        root.addView(video,new FrameLayout.LayoutParams(-1,-1));
        pairing=new LinearLayout(this);pairing.setOrientation(LinearLayout.VERTICAL);pairing.setGravity(Gravity.CENTER);pairing.setPadding(40,20,40,20);
        root.addView(pairing,new FrameLayout.LayoutParams(-1,-1));
        pairing.addView(label("Голубой экран TV",34));
        details=label("Подготавливаю защищённое подключение…",24);pairing.addView(details);
        state=label("",17);pairing.addView(state);
        Button permission=new Button(this);permission.setText("Разрешить возврат экрана после сна Mac");
        permission.setOnClickListener(v -> startActivity(new Intent(android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,android.net.Uri.parse("package:"+getPackageName()))));
        if(!android.provider.Settings.canDrawOverlays(this))pairing.addView(permission);
        Button forget=new Button(this);forget.setText("Забыть все Mac");forget.setOnClickListener(v -> { if(receiver!=null)receiver.forget(); });pairing.addView(forget);
        Button close=new Button(this);close.setText("Выключить приёмник");close.setOnClickListener(v -> { stopService(new Intent(this,ReceiverService.class));finish(); });pairing.addView(close);
        setContentView(root);
        startForegroundService(new Intent(this,ReceiverService.class));
    }
    @Override public void onStart() { super.onStart();setTurnScreenOn(true);getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);bindService(new Intent(this,ReceiverService.class),connection,BIND_AUTO_CREATE); }
    @Override public void onStop() {
        if(receiver!=null)receiver.detach(this);
        if(bound) { unbindService(connection);bound=false; }
        receiver=null;super.onStop();
    }
    private TextView label(String text,int size) {
        TextView view=new TextView(this);view.setText(text);view.setTextSize(size);view.setTextColor(Color.WHITE);view.setGravity(Gravity.CENTER);view.setPadding(10,8,10,8);return view;
    }
    void waiting(String pin,String fingerprint,String message) {
        pairing.setVisibility(View.VISIBLE);
        String ip="";
        try {
            for(java.net.NetworkInterface network:java.util.Collections.list(java.net.NetworkInterface.getNetworkInterfaces()))
                if(network.isUp() && !network.isLoopback()) for(java.net.InetAddress address:java.util.Collections.list(network.getInetAddresses()))
                    if(address instanceof java.net.Inet4Address && address.isSiteLocalAddress())ip+=address.getHostAddress()+"  ";
        } catch(Exception ignored){}
        details.setText(pin==null ? "Подготавливаю подключение…" : "IP: "+ip.trim()+"\nКод: "+pin+"\nУстройство: "+fingerprint);
        state.setText(message+"\nПосле сна Mac телевизор вернётся к обычному экрану.\nПриёмник можно свернуть; сохранённый Mac сможет подключиться снова.");
    }
    void applyMode(DisplayCapabilities.Mode mode) {
        WindowManager.LayoutParams params=getWindow().getAttributes();params.preferredDisplayModeId=mode.nativeID;getWindow().setAttributes(params);
        video.getHolder().setFixedSize(mode.width,mode.height);
        Surface surface=video.getHolder().getSurface();
        if(surface!=null && surface.isValid())surface.setFrameRate(mode.fpsMilli/1000f,Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE);
    }
    void video() { pairing.setVisibility(View.GONE); }
    void returnToTV() {
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        startActivity(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    }
}
