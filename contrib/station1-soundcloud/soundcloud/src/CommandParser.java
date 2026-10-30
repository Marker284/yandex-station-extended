package me.hackalice.station.soundcloud;
import java.util.*;
import java.util.regex.*;

/** Explicit SoundCloud titles; generic controls are accepted only in SoundCloud mode. */
public final class CommandParser {
    static final int FLAGS=Pattern.CASE_INSENSITIVE|Pattern.UNICODE_CASE;
    static final String CLOUD="(?:sound\\s*cloud|саунд\\s*клауд(?:е)?)";
    static final Pattern PREFIX=Pattern.compile("^(?:найди|ищи|поиск|включи|поставь|сыграй)(?:\\s+(?:мне|пожалуйста))?\\s+(?:в|на)\\s+"+CLOUD+"[\\s,:—-]+(.{1,180})$",FLAGS);
    static final Pattern SUFFIX=Pattern.compile("^(?:включи|поставь|сыграй|найди)\\s+(.{1,180}?)\\s+(?:в|на|из)\\s+"+CLOUD+"[.!?]*$",FLAGS);
    static String clean(String text){
        if(text==null)return "";
        return text.replace('\u00a0',' ').replace("\u200b","").replaceAll("\\s+"," ").trim().replaceFirst("(?iu)^алиса[\\s,.:!]+","").replaceFirst("[.!?]+$","");
    }
    public static String parse(String text){
        text=clean(text);Matcher m=PREFIX.matcher(text);if(!m.matches())m=SUFFIX.matcher(text);
        return m.matches()?m.group(1).trim():null;
    }
    public static final class Control {
        public final String command;public final long seconds;
        Control(String command,long seconds){this.command=command;this.seconds=seconds;}
    }
    public static Control control(String text){
        text=clean(text).toLowerCase(new Locale("ru")).replace('ё','е');
        if(text.matches("(?:стоп|останови|пауза|останови музыку|останови трек|поставь на паузу|выключи музыку)"))return new Control("pause",0);
        if(text.matches("(?:продолжи|продолжай|продолжи воспроизведение|продолжи музыку|сними с паузы)"))return new Control("resume",0);
        if(text.matches("(?:следующий|следующий трек|переключи трек)"))return new Control("next",0);
        if(text.matches("(?:предыдущий|предыдущий трек)"))return new Control("previous",0);
        if(text.matches("(?:сначала|с начала|включи сначала|в начало|перемотай в начало)"))return new Control("position",0);
        Matcher m=Pattern.compile("^(?:перемотай|перемотка|промотай)(?: (вперед|назад))? (?:на |к )?([а-я0-9 ]+?) (секунд(?:у|ы)?|минут(?:у|ы)?)(?: (вперед|назад))?$",FLAGS).matcher(text);
        if(!m.matches())return null;
        long amount=number(m.group(2));if(amount<0)return null;
        if(m.group(3).startsWith("мин"))amount*=60;
        if(amount>86400)return null;
        if("назад".equals(m.group(1))||"назад".equals(m.group(4)))amount=-amount;
        return new Control("seek",amount);
    }
    static long number(String value){
        if(value.matches("[0-9]{1,5}"))return Long.parseLong(value);
        String[] names={"ноль","один","два","три","четыре","пять","шесть","семь","восемь","девять","десять","одиннадцать","двенадцать","тринадцать","четырнадцать","пятнадцать","шестнадцать","семнадцать","восемнадцать","девятнадцать","двадцать","тридцать","сорок","пятьдесят","шестьдесят","семьдесят","восемьдесят","девяносто","сто"};
        value=value.replace("одну","один").replace("одна","один").replace("две","два");
        long total=0;for(String word:value.split(" ")){int i=Arrays.asList(names).indexOf(word);if(i<0)return -1;total+=i<20?i:i<28?(i-18)*10:100;}
        return total;
    }
}
