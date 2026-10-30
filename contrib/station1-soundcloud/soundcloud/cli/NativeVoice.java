import java.io.*;
import java.net.*;
import java.util.*;
import org.json.JSONObject;
import me.hackalice.station.soundcloud.CommandParser;

/** Station 1's local Quasar IPC. No microphone, screen, cloud proxy or speech log. */
public final class NativeVoice {
    static final int MAX_FRAME=1024*1024;
    final File directory;
    final int alicePort;
    Socket alice;
    boolean armed,handled,active,connected;
    String phrase="",error="",lastRequest="";
    int state,requests,controls,reconnects;
    NativeVoice(File directory)throws Exception{
        this.directory=directory;
        JSONObject config=new JSONObject(readText(new File("/system/vendor/quasar/quasar.cfg")));
        alicePort=port(config,"aliced");
        active=new File(directory,"soundcloud-active").isFile();
    }
    static int port(JSONObject config,String service)throws Exception{
        int value=config.getJSONObject(service).getInt("port");
        if(value<1||value>65535)throw new IOException("Invalid local service port");return value;
    }
    static String readText(File file)throws Exception{
        FileInputStream in=new FileInputStream(file);ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] bytes=new byte[4096];int count;
        try{while((count=in.read(bytes))!=-1){if(out.size()+count>MAX_FRAME)throw new IOException("Configuration too large");out.write(bytes,0,count);}}finally{in.close();}
        return new String(out.toByteArray(),"UTF-8");
    }
    static final class Fields {
        final Map<Integer,Long> numbers=new HashMap<Integer,Long>();
        final Map<Integer,byte[]> bytes=new HashMap<Integer,byte[]>();
        String text(int field)throws Exception{return bytes.containsKey(field)?new String(bytes.get(field),"UTF-8"):"";}
        long number(int field,long fallback){Long value=numbers.get(field);return value==null?fallback:value;}
    }
    static long varint(byte[] data,int[] offset)throws IOException{
        long value=0;
        for(int shift=0;shift<64;shift+=7){
            if(offset[0]>=data.length)throw new EOFException();
            int b=data[offset[0]++]&255;
            if(shift==63&&b>1)throw new IOException("Varint overflow");
            value|=(long)(b&127)<<shift;if((b&128)==0)return value;
        }
        throw new IOException("Invalid varint");
    }
    static Fields decode(byte[] data)throws IOException{
        if(data.length>MAX_FRAME)throw new IOException("Frame too large");
        Fields result=new Fields();int[] offset={0};
        while(offset[0]<data.length){
            long key=varint(data,offset);int field=(int)(key>>>3),wire=(int)(key&7);
            if(field<1||field>0x1fffffff)throw new IOException("Invalid field");
            if(wire==0)result.numbers.put(field,varint(data,offset));
            else if(wire==1||wire==5){offset[0]+=wire==1?8:4;if(offset[0]>data.length)throw new EOFException();}
            else if(wire==2){
                long length=varint(data,offset);
                if(length<0||length>data.length-offset[0])throw new EOFException();
                int end=offset[0]+(int)length;result.bytes.put(field,Arrays.copyOfRange(data,offset[0],end));offset[0]=end;
            }else throw new IOException("Unsupported wire type");
        }
        return result;
    }
    static void varint(ByteArrayOutputStream out,long value){while((value&~127L)!=0){out.write((int)value&127|128);value>>>=7;}out.write((int)value);}
    static byte[] number(int field,long value){ByteArrayOutputStream out=new ByteArrayOutputStream();varint(out,(long)field<<3);varint(out,value);return out.toByteArray();}
    static byte[] bytes(int field,byte[] value){ByteArrayOutputStream out=new ByteArrayOutputStream();varint(out,((long)field<<3)|2);varint(out,value.length);out.write(value,0,value.length);return out.toByteArray();}
    static byte[] join(byte[]... parts){ByteArrayOutputStream out=new ByteArrayOutputStream();for(byte[] part:parts)out.write(part,0,part.length);return out.toByteArray();}
    static byte[] envelope(int type,byte[] payload)throws Exception{
        return join(bytes(1,UUID.randomUUID().toString().getBytes("UTF-8")),bytes(252,payload),number(253,type));
    }
    static void send(Socket socket,byte[] payload)throws Exception{
        OutputStream out=socket.getOutputStream();int n=payload.length;
        out.write(new byte[]{(byte)n,(byte)(n>>>8),(byte)(n>>>16),(byte)(n>>>24)});out.write(payload);out.flush();
    }
    static byte[] frame(InputStream in)throws Exception{
        byte[] header=new byte[4];exact(in,header);long n=0;for(int i=0;i<4;i++)n|=(long)(header[i]&255)<<(8*i);
        if(n>MAX_FRAME)throw new IOException("Native frame too large");byte[] payload=new byte[(int)n];exact(in,payload);return payload;
    }
    static void exact(InputStream in,byte[] data)throws Exception{
        int offset=0;while(offset<data.length){int n=in.read(data,offset,data.length-offset);if(n<0)throw new EOFException();offset+=n;}
    }
    static Socket connect(int port)throws Exception{
        Socket socket=new Socket();socket.connect(new InetSocketAddress("127.0.0.1",port),4000);socket.setTcpNoDelay(true);return socket;
    }
    void cancelNative()throws Exception{
        // Remoting.AliceCapabilityMethod.CANCEL_DIALOG_AND_CLEAR_QUEUE.
        // Only explicit SoundCloud requests/controls use this.
        byte[] method=join(bytes(7,"AliceCapability".getBytes("UTF-8")),bytes(8,number(1,6)));
        send(alice,envelope(210,method));
    }
    void broadcast(String command,String query,long seconds)throws Exception{
        List<String> args=new ArrayList<String>(Arrays.asList("/system/bin/am","broadcast","--include-stopped-packages","-n","org.schabi.newpipe/org.schabi.newpipe.station.StationSoundCloudReceiver","--es","command",command));
        if(query!=null){args.add("--es");args.add("query");args.add(query);}
        args.add("--el");args.add("seconds");args.add(String.valueOf(seconds));
        Process child=new ProcessBuilder(args).redirectErrorStream(true).start();
        InputStream output=child.getInputStream();byte[] discard=new byte[1024];while(output.read(discard)!=-1){}output.close();
        if(child.waitFor()!=0)throw new IOException("Player command failed");
    }
    void command(String text)throws Exception{
        String query=CommandParser.parse(text);
        CommandParser.Control control=active?CommandParser.control(text):null;
        if(query==null&&control==null){
            if(text.toLowerCase(new Locale("ru")).matches(".*(?:включи|поставь|сыграй) .+")){active=false;new File(directory,"soundcloud-active").delete();}
            return;
        }
        cancelNative();
        if(query!=null){broadcast("play",query,0);active=true;new File(directory,"soundcloud-active").createNewFile();requests++;}
        else{broadcast(control.command,null,control.seconds);controls++;}
        error="";diagnostic();
    }
    void event(byte[] data)throws Exception{
        Fields outer=decode(data);if(!outer.bytes.containsKey(252))return;
        Fields body=decode(outer.bytes.get(252));
        if(outer.number(253,0)==210){
            if(!"AliceCapability".equals(body.text(7))||!body.bytes.containsKey(18))return;
            Fields listener=decode(body.bytes.get(18));
            if(listener.number(1,0)!=0||!listener.bytes.containsKey(2))return;
            body=decode(listener.bytes.get(2));
        }else if(outer.number(253,0)!=3)return;
        int next=(int)body.number(1,state);
        if(next==1&&state!=1){armed=true;handled=false;phrase="";}
        state=next;
        if(body.bytes.containsKey(2))phrase=body.text(2);
        if(armed&&!handled&&state!=1&&phrase.length()>0){
            handled=true;String request=body.text(7);
            if(request.length()>0&&request.equals(lastRequest))return;
            lastRequest=request;if(phrase.length()<=512)command(phrase);
        }
    }
    void diagnostic(){
        try{FileOutputStream out=new FileOutputStream(new File(directory,"voice-native.json"));out.write(("{\"connected\":"+connected+",\"requests\":"+requests+",\"controls\":"+controls+",\"reconnects\":"+reconnects+",\"error\":\""+error+"\"}").getBytes("UTF-8"));out.close();}catch(Exception ignored){}
    }
    public static void main(String[] args)throws Exception{
        NativeVoice voice=new NativeVoice(new File(args[0]));
        if(args.length==3&&args[1].equals("--command")){
            voice.alice=connect(voice.alicePort);try{voice.command(args[2]);}finally{voice.alice.close();}return;
        }
        while(true){
            try{
                voice.alice=connect(voice.alicePort);voice.connected=true;voice.armed=false;voice.state=0;voice.diagnostic();
                InputStream in=voice.alice.getInputStream();while(true)voice.event(frame(in));
            }catch(Exception failure){voice.connected=false;voice.error=failure.getClass().getSimpleName();voice.reconnects++;voice.diagnostic();}
            finally{if(voice.alice!=null)try{voice.alice.close();}catch(Exception ignored){}}
            Thread.sleep(2000);
        }
    }
}
