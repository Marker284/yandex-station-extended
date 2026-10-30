import me.hackalice.station.soundcloud.CommandParser;

public final class Check {
    public static void main(String[] args) throws Exception {
        String base = "vless://00000000-0000-0000-0000-000000000001@example.com:443";
        String sample = base + "?security=reality&spx=%252F&pbk=a%2Bb#Test";
        String repaired = VlessImport.normalize(sample);
        if (!repaired.equals(base + "?security=reality&spx=/&pbk=a%2Bb#Test")) throw new AssertionError("VLESS normalization corrupts query");
        if (!VlessImport.normalize(base + "#My VPN").endsWith("#My%20VPN")) throw new AssertionError("Rejects a profile name with spaces");
        for (String invalid : new String[] {"", "vmess://anything", base + "\nother", base.replace(":443", ":0"), base.replace("example.com", ""), base.replace("000000000001", "invalid")}) {
            try { VlessImport.normalize(invalid); throw new AssertionError("Accepted invalid VLESS"); }
            catch (IllegalArgumentException expected) { }
        }
        if (!"Daft Punk".equals(CommandParser.parse("Алиса, найди в Саундклауде Daft Punk"))) throw new AssertionError("Voice command rejected");
        if (!"Daft Punk".equals(CommandParser.parse("Алиса, включи Daft Punk в SoundCloud"))) throw new AssertionError("Play command rejected");
        if (!"Daft Punk".equals(CommandParser.parse("Включи в Саундклауде Daft Punk"))) throw new AssertionError("Play prefix rejected");
        for (String stop : new String[]{"Алиса, стоп", "Поставь на паузу"})
            if (!"pause".equals(CommandParser.control(stop).command)) throw new AssertionError("Stop rejected");
        if (CommandParser.control("Алиса, перемотай на 30 секунд").seconds != 30) throw new AssertionError("Numeric seek failed");
        if (CommandParser.control("Перемотай назад на двадцать пять секунд").seconds != -25) throw new AssertionError("Word seek failed");
        if (CommandParser.control("Перемотай на две минуты назад").seconds != -120) throw new AssertionError("Minute seek failed");
        for (String invalid : new String[]{"Перемотай на 99999 секунд", "Перемотай на минус 10 секунд", "Алиса, расскажи про стоп", "Где мои пять минут"})
            if (CommandParser.control(invalid) != null) throw new AssertionError("Unrelated control accepted");
        byte[] packet=NativeVoice.join(NativeVoice.bytes(252,NativeVoice.bytes(2,"Включи в Саундклауде NCS".getBytes("UTF-8"))),NativeVoice.number(253,3));
        NativeVoice.Fields envelope=NativeVoice.decode(packet);
        if(envelope.number(253,0)!=3||!NativeVoice.decode(envelope.bytes.get(252)).text(2).endsWith("NCS"))throw new AssertionError("Native IPC decoding failed");
        for(byte[] invalid:new byte[][]{{0},{10,127,1},{(byte)128},{15}}){
            try{NativeVoice.decode(invalid);throw new AssertionError("Invalid protobuf accepted");}catch(java.io.IOException expected){}
        }
        for (String other : new String[] {"Алиса, включи музыку", "Найди видео Daft Punk", "Как работает SoundCloud", "Алиса, найди в Саундклауде "})
            if (CommandParser.parse(other) != null) throw new AssertionError("Unrelated Alice command intercepted");
        System.out.println("VLESS boundary validation, encoding and Alice command checks passed");
    }
}
