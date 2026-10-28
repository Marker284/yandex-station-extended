import java.io.*;
import java.net.*;
import java.util.*;
import java.util.regex.*;

/** Reads one key from stdin, passes it to v2rayNG's supported share importer. */
public final class VlessImport {
    static String normalize(String link) throws Exception {
        link = link.trim();
        int fragment = link.indexOf('#');
        if (link.length() > 8192 || !link.startsWith("vless://") || Pattern.compile("[\\x00-\\x1f\\x7f]").matcher(link).find()
            || Pattern.compile("\\s").matcher(fragment < 0 ? link : link.substring(0, fragment)).find())
            throw new IllegalArgumentException("Expected a single VLESS link without spaces");
        if (fragment >= 0) link = link.substring(0, fragment) + link.substring(fragment).replace(" ", "%20");
        URI uri;
        try { uri = new URI(link); } catch (URISyntaxException bad) { throw new IllegalArgumentException("Invalid URI"); }
        if (uri.getHost() == null || uri.getPort() < 1 || uri.getPort() > 65535 || uri.getRawUserInfo() == null
            || !uri.getRawUserInfo().matches("[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"))
            throw new IllegalArgumentException("Invalid VLESS server, port or UUID");
        return VlessLink.normalize(link);
    }
    public static void main(String[] args) {
        try {
            InputStreamReader input = new InputStreamReader(System.in, "UTF-8");
            StringBuilder key = new StringBuilder(); int c;
            while ((c = input.read()) != -1 && c != '\n') {
                if (key.length() >= 8192) throw new IllegalArgumentException("VLESS link is too long");
                key.append((char)c);
            }
            String link = normalize(key.toString());
            // UrlSchemeActivity decodes ACTION_SEND text once. Encode once to preserve +, %, # and query values.
            Process process = new ProcessBuilder("/system/bin/am", "start", "-a", "android.intent.action.SEND",
                "-t", "text/plain", "-n", "com.v2ray.ang/com.v2ray.ang.ui.UrlSchemeActivity",
                "--es", "android.intent.extra.TEXT", URLEncoder.encode(link, "UTF-8"))
                .redirectErrorStream(true).start();
            ByteArrayOutputStream output = new ByteArrayOutputStream(); byte[] bytes = new byte[1024]; int n;
            try { while ((n = process.getInputStream().read(bytes)) != -1) if (output.size() < 32768) output.write(bytes, 0, n); }
            finally { process.getInputStream().close(); }
            String result = new String(output.toByteArray(), "UTF-8");
            if (process.waitFor() != 0 || result.contains("Error:") || result.contains("Exception")) throw new IOException("Cannot open v2rayNG importer");
            // Its importer starts MainActivity before the asynchronous import finishes.
            // Recreate only that activity task so onResume reloads the saved profile list.
            Thread.sleep(2000);
            Process refresh = new ProcessBuilder("/system/bin/am", "start", "-f", "0x10008000", "-n", "com.v2ray.ang/.ui.MainActivity").redirectErrorStream(true).start();
            try { while (refresh.getInputStream().read(bytes) != -1) { } } finally { refresh.getInputStream().close(); }
            if (refresh.waitFor() != 0) throw new IOException("Cannot reopen v2rayNG");
            System.out.println("VLESS sent to v2rayNG. Wait for its import confirmation, select the new profile and connect.");
        } catch (Exception failure) {
            // Never print the supplied link or URI parser exceptions, which can include credentials.
            System.err.println(failure instanceof IllegalArgumentException ? "Invalid VLESS link: check its format, UUID, server and port." : "Import failed. Check that v2rayNG is installed.");
            System.exit(1);
        }
    }
}
