import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.media.session.MediaController;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.os.Looper;
import java.io.*;
import java.util.*;
import org.xmlpull.v1.XmlPullParser;
import org.xmlpull.v1.XmlPullParserFactory;
import java.security.MessageDigest;
import org.json.JSONObject;

/** Official Spotify TV deep links and Android media session. Search starts playback. */
public final class SpotifyControl {
    static final String PACKAGE="com.spotify.tv.android";
    static final String SIGNER="fd450f5f94b9dba0ae7f6b19e0b512e041ea7fc2cc291b71737b319ba7f4b3d4";
    static Context context;
    static Context context()throws Exception{
        if(context==null){
            if(Looper.myLooper()==null)Looper.prepareMainLooper();
            Class<?> type=Class.forName("android.app.ActivityThread");
            Object thread=type.getMethod("systemMain").invoke(null);
            context=(Context)type.getMethod("getSystemContext").invoke(thread);
        }
        return context;
    }
    static void verify(String path)throws Exception{
        PackageInfo info=context().getPackageManager().getPackageArchiveInfo(path,PackageManager.GET_SIGNATURES);
        if(info==null||!PACKAGE.equals(info.packageName)||info.versionCode!=2340200||info.signatures==null||info.signatures.length!=1)
            throw new SecurityException("Unexpected Spotify package/version");
        byte[] digest=MessageDigest.getInstance("SHA-256").digest(info.signatures[0].toByteArray());
        StringBuilder hex=new StringBuilder();for(byte b:digest)hex.append(String.format("%02x",b&255));
        if(!SIGNER.equals(hex.toString()))throw new SecurityException("Unexpected Spotify signing certificate");
    }
    static MediaController session()throws Exception{
        MediaSessionManager manager=(MediaSessionManager)context().getSystemService(Context.MEDIA_SESSION_SERVICE);
        for(MediaController controller:manager.getActiveSessions(null))if(PACKAGE.equals(controller.getPackageName()))return controller;
        return null;
    }
    static void open(String action,String data)throws Exception{
        List<String> args=new ArrayList<String>(Arrays.asList("/system/bin/am","start","-a",action,"-n",PACKAGE+"/.SpotifyTVActivity"));
        if(data!=null){args.add("-d");args.add(data);}
        run(args.toArray(new String[args.size()]));
    }
    static String read(File file)throws Exception{
        FileInputStream in=new FileInputStream(file);ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] buffer=new byte[4096];int count;
        try{while((count=in.read(buffer))!=-1){if(out.size()+count>1024*1024)throw new IOException("Response too large");out.write(buffer,0,count);}}finally{in.close();}
        return new String(out.toByteArray(),"UTF-8");
    }
    static void run(String... command)throws Exception{
        Process child=new ProcessBuilder(command).redirectErrorStream(true).start();
        long deadline=System.currentTimeMillis()+25000;
        while(true){try{if(child.exitValue()!=0)throw new IOException("Android command failed");break;}catch(IllegalThreadStateException running){if(System.currentTimeMillis()>deadline){child.destroy();throw new IOException("Android command timed out");}Thread.sleep(100);}}
        child.getInputStream().close();
    }
    static void extract(String archive,String destination)throws Exception{
        // Station 1's BusyBox unzip cannot read stored ZIP entries with data descriptors.
        java.util.zip.ZipFile zip=new java.util.zip.ZipFile(archive);
        try{
            for(String name:new String[]{"com.spotify.tv.android.apk","config.armeabi_v7a.apk","config.en.apk","config.ru.apk","config.xhdpi.apk"}){
                java.util.zip.ZipEntry entry=zip.getEntry(name);
                if(entry==null||entry.getSize()<1||entry.getSize()>32*1024*1024)throw new IOException("Invalid APK archive entry");
                InputStream in=zip.getInputStream(entry);
                OutputStream out=new FileOutputStream(new File(destination,name));long count=0;byte[] buffer=new byte[8192];int n;
                try{while((n=in.read(buffer))!=-1){count+=n;if(count>entry.getSize())throw new IOException("APK entry too large");out.write(buffer,0,n);}}
                finally{try{in.close();}finally{out.close();}}
                if(count!=entry.getSize())throw new IOException("Truncated APK entry");
            }
        }finally{zip.close();}
    }
    static final class Node {
        String text,bounds;
        Node(String text,String bounds){this.text=text;this.bounds=bounds;}
    }
    static List<Node> ui()throws Exception{
        File dir=new File("/data/station1-spotify");dir.mkdirs();File file=new File(dir,"pair-ui.xml");
        run("/system/bin/uiautomator","dump",file.toString());
        List<Node> nodes=new ArrayList<Node>();
        try{
            XmlPullParser parser=XmlPullParserFactory.newInstance().newPullParser();parser.setInput(new StringReader(read(file)));
            while(parser.next()!=XmlPullParser.END_DOCUMENT)if(parser.getEventType()==XmlPullParser.START_TAG&&"node".equals(parser.getName())&&PACKAGE.equals(parser.getAttributeValue(null,"package"))){
                String text=parser.getAttributeValue(null,"text");if(text==null||text.length()==0)text=parser.getAttributeValue(null,"content-desc");
                if(text!=null&&text.length()>0)nodes.add(new Node(text,parser.getAttributeValue(null,"bounds")));
            }
        }finally{file.delete();}
        return nodes;
    }
    static void login()throws Exception{
        open(Intent.ACTION_MAIN,null);
        for(int attempt=0;attempt<8;attempt++){
            Thread.sleep(1500);List<Node> nodes=ui();StringBuilder code=new StringBuilder();boolean pair=false;
            for(Node node:nodes){if(node.text.contains("spotify.com/pair"))pair=true;if(node.text.matches("[A-Z0-9]"))code.append(node.text);}
            if(pair&&code.length()==6){System.out.println("https://spotify.com/pair\nCode: "+code+"\nComplete sign-in in your browser. This code is temporary.");return;}
            boolean clicked=false;
            for(Node node:nodes)if(node.text.matches("(?iu)(Log in|Log in with code|Войти|Войти с помощью кода|Войти по коду)")){
                java.util.regex.Matcher numbers=java.util.regex.Pattern.compile("[0-9]+").matcher(node.bounds==null?"":node.bounds);int[] p=new int[4];int i=0;while(i<4&&numbers.find())p[i++]=Integer.parseInt(numbers.group());
                if(i==4&&p[2]>p[0]&&p[3]>p[1]){run("/system/bin/input","tap",String.valueOf((p[0]+p[2])/2),String.valueOf((p[1]+p[3])/2));clicked=true;break;}
            }
            if(!clicked&&session()!=null){System.out.println("Spotify playback session available. To change accounts, use logout first.");return;}
        }
        throw new IllegalStateException("No pairing code: account may already be linked, or Spotify shows an account/region error. Check the saved country and the Station's network, then use logout/login if needed.");
    }
    static String title()throws Exception{
        MediaController controller=session();
        if(controller==null)return null;
        android.media.MediaMetadata metadata=controller.getMetadata();
        return metadata==null?null:metadata.getString(android.media.MediaMetadata.METADATA_KEY_TITLE);
    }
    static boolean waitForTrack(String previous,long timeout)throws Exception{
        long deadline=android.os.SystemClock.elapsedRealtime()+timeout;
        while(android.os.SystemClock.elapsedRealtime()<deadline){
            String current=title();
            if(current!=null&&(previous==null||!previous.equals(current)))return true;
            Thread.sleep(500);
        }
        return false;
    }
    static void play(String query)throws Exception{
        MediaController controller=session();
        if(controller!=null){
            PlaybackState state=controller.getPlaybackState();
            if(state!=null&&state.getState()==PlaybackState.STATE_PLAYING)controller.getTransportControls().pause();
        }
        String previous=title();
        String uri="spotify:search:"+java.net.URLEncoder.encode(query,"UTF-8").replace("+","%20");
        open(Intent.ACTION_VIEW,uri);
        if(waitForTrack(previous,8000))return;
        // Клиент показал выдачу и молчит. Холодный старт надёжен, но идёт 21-24 секунды.
        run("/system/bin/am","force-stop",PACKAGE);
        Thread.sleep(1000);
        open(Intent.ACTION_VIEW,uri);
    }
    static void dispatch(String command,String query,long seconds)throws Exception{
        if("play".equals(command)||"search".equals(command)){
            if(query==null||query.trim().length()==0||query.length()>180)throw new IllegalArgumentException("Invalid search query");
            play(query);
            return;
        }
        MediaController controller=session();
        long deadline=android.os.SystemClock.elapsedRealtime()+20000;
        while(controller==null&&android.os.SystemClock.elapsedRealtime()<deadline){Thread.sleep(500);controller=session();}
        if(controller==null){
            // Stop must also cancel a slow cold launch before a media session exists.
            if("pause".equals(command)){run("/system/bin/am","force-stop",PACKAGE);return;}
            throw new IllegalStateException("Spotify is not ready: wait for the client to start, then retry");
        }
        MediaController.TransportControls controls=controller.getTransportControls();
        if("pause".equals(command))controls.pause();
        else if("resume".equals(command))controls.play();
        else if("next".equals(command))controls.skipToNext();
        else if("previous".equals(command))controls.skipToPrevious();
        else if("seek".equals(command)||"position".equals(command)){
            PlaybackState state=controller.getPlaybackState();
            if(state==null)throw new IllegalStateException("No playback position");
            long current=state.getPosition();
            if(current<0)throw new IllegalStateException("Playback position unavailable");
            if(state.getState()==PlaybackState.STATE_PLAYING&&state.getLastPositionUpdateTime()>0)
                current+=(long)((android.os.SystemClock.elapsedRealtime()-state.getLastPositionUpdateTime())*state.getPlaybackSpeed());
            long position="position".equals(command)?0:Math.max(0,current+Math.max(-86400,Math.min(86400,seconds))*1000);
            android.media.MediaMetadata metadata=controller.getMetadata();
            if(metadata!=null){long duration=metadata.getLong(android.media.MediaMetadata.METADATA_KEY_DURATION);if(duration>0)position=Math.min(position,duration);}
            controls.seekTo(position);
        }else throw new IllegalArgumentException("Unknown command");
    }
    public static void main(String[] args){
        try{execute(args);}catch(Exception failure){
            System.err.println("Spotify: "+(failure.getMessage()==null?failure.getClass().getSimpleName():failure.getMessage()));
            System.exit(1);
        }
    }
    static void execute(String[] args)throws Exception{
        if(args.length==0||"info".equals(args[0])){
            MediaController controller=session();JSONObject result=new JSONObject().put("session",controller!=null);
            if(controller!=null){
                result.put("package",controller.getPackageName());
                PlaybackState state=controller.getPlaybackState();if(state!=null)result.put("state",state.getState()).put("position",state.getPosition()).put("actions",state.getActions());
                android.media.MediaMetadata metadata=controller.getMetadata();
                if(metadata!=null)result.put("title",metadata.getString(android.media.MediaMetadata.METADATA_KEY_TITLE)).put("artist",metadata.getString(android.media.MediaMetadata.METADATA_KEY_ARTIST));
            }
            System.out.println(result);return;
        }
        if("extract".equals(args[0])){extract(args[1],args[2]);return;}
        if("verify".equals(args[0])){verify(args[1]);System.out.println("Spotify certificate verified");return;}
        if("open".equals(args[0])){open(Intent.ACTION_MAIN,null);return;}
        if("login".equals(args[0])){login();return;}
        long seconds="seek".equals(args[0])&&args.length>1?Long.parseLong(args[1]):0;
        dispatch(args[0],args.length>1?args[1]:null,seconds);
    }
}
