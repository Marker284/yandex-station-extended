import java.net.URLDecoder;
import java.net.URLEncoder;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Android 6 v2rayNG's URL decoder can leave a REALITY spider path percent encoded. */
final class VlessLink {
    static String normalize(String link) throws Exception {
        if (!link.startsWith("vless://")) return link;
        Matcher match = Pattern.compile("([?&]spx=)([^&#]*)").matcher(link);
        if (match.find()) {
            String value = URLDecoder.decode(match.group(2), "UTF-8");
            for (int i = 0; i < 3 && value.startsWith("%"); i++) value = URLDecoder.decode(value, "UTF-8");
            if (value.startsWith("/")) return link.substring(0, match.start(2)) + "/"
                + URLEncoder.encode(value.substring(1), "UTF-8").replace("+", "%20").replace("%2F", "/")
                + link.substring(match.end(2));
        }
        return link;
    }
}
