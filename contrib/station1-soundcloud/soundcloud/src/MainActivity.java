package me.hackalice.station.soundcloud;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.widget.Toast;

public class MainActivity extends Activity {
    @Override public void onCreate(Bundle state){
        super.onCreate(state);
        String query=getIntent().getStringExtra("query");
        if(query==null||query.trim().isEmpty()){
            Intent launcher=getPackageManager().getLaunchIntentForPackage("org.schabi.newpipe");
            if(launcher!=null)startActivity(launcher);
        }else open(this,query.substring(0,Math.min(query.length(),180)));
        finish();
    }
    static boolean open(Context context,String query){
        return launch(context,query);
    }
    static boolean launch(Context context,String query){
        try{
            if(query==null||query.trim().isEmpty()||query.length()>180)return false;
            if(context.getPackageManager().getLaunchIntentForPackage("org.schabi.newpipe")==null)throw new IllegalStateException();
            send(context,"play",query,0);
            context.getSharedPreferences("voice",0).edit().putBoolean("soundcloud",true).apply();
            return true;
        }catch(Exception e){Toast.makeText(context,"NewPipe не установлен",Toast.LENGTH_LONG).show();return false;}
    }
    static void send(Context context,String command,String query,long seconds){
        Intent i=new Intent();i.setClassName("org.schabi.newpipe","org.schabi.newpipe.station.StationSoundCloudReceiver");
        i.addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES);
        i.putExtra("command",command);i.putExtra("query",query);i.putExtra("seconds",seconds);
        context.sendBroadcast(i);
    }
}
