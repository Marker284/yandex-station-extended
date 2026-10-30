/* SPDX-License-Identifier: GPL-3.0-or-later */
package org.schabi.newpipe.station;

import android.app.Service;
import android.content.Intent;
import android.content.ComponentName;
import android.content.ServiceConnection;
import android.content.Context;
import android.os.Handler;
import android.os.IBinder;
import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.*;

/** Adapter for the exact pinned NewPipe 0.29.1 APK; names include its R8 relocation. */
public final class StationSoundCloudService extends Service {
    final Handler main = new Handler();
    final ExecutorService worker = Executors.newSingleThreadExecutor();
    volatile long generation;
    int started, completed, controls, failures;
    String error = "";
    Object nativeService;
    boolean bound;
    final ServiceConnection connection = new ServiceConnection() {
        public void onServiceConnected(ComponentName name, IBinder binder) {
            try {
                for (Field field : binder.getClass().getDeclaredFields()) {
                    field.setAccessible(true);
                    Object value = field.get(binder);
                    if (value instanceof java.lang.ref.WeakReference) value = ((java.lang.ref.WeakReference<?>) value).get();
                    if (value instanceof Service) { nativeService = value; break; }
                }
            } catch (Exception e) { failed(e); }
        }
        public void onServiceDisconnected(ComponentName name) { nativeService = null; bound = false; }
    };
    Object getPlayer() throws Exception {
        if (nativeService == null) return null;
        for (Field field : nativeService.getClass().getDeclaredFields()) {
            if (field.getType().getName().equals("org.schabi.newpipe.player.Player")) {
                field.setAccessible(true); return field.get(nativeService);
            }
        }
        return null;
    }
    @Override public IBinder onBind(Intent intent) { return null; }
    static Class<?> type(String name) throws Exception { return Class.forName(name); }
    static Object call(Object target, String name, Class<?>[] signature, Object... args) throws Exception {
        Class<?> owner = target instanceof Class ? (Class<?>) target : target.getClass();
        Method method = owner.getDeclaredMethod(name, signature);
        method.setAccessible(true);
        return method.invoke(target instanceof Class ? null : target, args);
    }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) return START_NOT_STICKY;
        final String command = intent.getStringExtra("command");
        if ("play".equals(command)) {
            final String query = intent.getStringExtra("query");
            if (query == null || query.trim().isEmpty() || query.length() > 180) return START_NOT_STICKY;
            final long request = ++generation;
            started++; diagnostic();
            worker.execute(new Runnable() { public void run() {
                try {
                    Object service = call(type("us.shandian.giga.util.Utility"), "getService", new Class<?>[]{int.class}, 1);
                    Method factoryMethod = type("org.schabi.newpipe.extractor.StreamingService").getMethod("getSearchQHFactory");
                    Object factory = factoryMethod.invoke(service);
                    Method fromQuery = type("org.schabi.newpipe.extractor.linkhandler.SearchQueryHandlerFactory").getMethod("fromQuery", String.class, String.class, List.class);
                    Object handler = fromQuery.invoke(factory, query.trim(), "", Collections.singletonList("tracks"));
                    Class<?> infoType = type("org.schabi.newpipe.extractor.search.SearchInfo");
                    Object info = infoType.getMethod("getInfo", type("org.schabi.newpipe.extractor.StreamingService"), type("org.schabi.newpipe.extractor.linkhandler.SearchQueryHandler")).invoke(null, service, handler);
                    List<?> items = (List<?>) type("org.schabi.newpipe.extractor.ListInfo").getMethod("getRelatedItems").invoke(info);
                    Class<?> trackType = type("org.schabi.newpipe.extractor.stream.StreamInfoItem");
                    Object first = null;
                    for (Object item : items) if (trackType.isInstance(item)) { first = item; break; }
                    if (first == null) throw new IllegalStateException("NoTrack");
                    final Object queue = type("org.schabi.newpipe.player.playqueue.SinglePlayQueue").getConstructor(trackType).newInstance(first);
                    main.post(new Runnable() { public void run() {
                        if (generation != request) return;
                        try {
                            call(type("androidx.sqlite.SQLite"), "playOnBackgroundPlayer", new Class<?>[]{android.content.Context.class, type("org.schabi.newpipe.player.playqueue.PlayQueue"), boolean.class}, StationSoundCloudService.this, queue, false);
                            if (!bound) {
                                Intent bind = new Intent("bind_player_holder_action").setClassName(StationSoundCloudService.this, "org.schabi.newpipe.player.PlayerService");
                                bound = bindService(bind, connection, Context.BIND_AUTO_CREATE);
                            }
                            completed++; error = ""; diagnostic();
                        } catch (Exception e) { failed(e); }
                    }});
                } catch (Exception e) { if (generation == request) failed(e); }
            }});
        } else {
            if ("stop".equals(command) || "pause".equals(command)) generation++;
            try {
                Object player = getPlayer();
                if (player == null) return START_NOT_STICKY;
                if ("stop".equals(command) || "pause".equals(command)) call(player, "pause", new Class<?>[0]);
                else if ("resume".equals(command)) call(player, "play", new Class<?>[0]);
                else if ("next".equals(command)) call(player, "playNext", new Class<?>[0]);
                else if ("previous".equals(command)) call(player, "playPrevious", new Class<?>[0]);
                else if ("seek".equals(command) || "position".equals(command)) {
                    long position = 0;
                    if ("seek".equals(command)) {
                        Field field = player.getClass().getDeclaredField("simpleExoPlayer"); field.setAccessible(true);
                        Object exo = field.get(player);
                        position = (Long) type("com.google.android.exoplayer2.Player").getMethod("getCurrentPosition").invoke(exo);
                    }
                    long seconds = Math.max(-86400, Math.min(86400, intent.getLongExtra("seconds", 0)));
                    call(player, "seekTo", new Class<?>[]{long.class}, Math.max(0, position + seconds * 1000));
                } else return START_NOT_STICKY;
                controls++; error = ""; diagnostic();
            } catch (Exception e) { failed(e); }
        }
        return START_NOT_STICKY;
    }
    void failed(Exception exception) {
        Throwable cause = exception;
        while (cause.getCause() != null) cause = cause.getCause();
        error = cause.getClass().getSimpleName(); failures++; diagnostic();
        try {
            StringBuilder trace = new StringBuilder(error);
            for (StackTraceElement frame : cause.getStackTrace()) trace.append('\n').append(frame.toString());
            java.io.FileOutputStream out = openFileOutput("station-soundcloud-error.txt", MODE_PRIVATE);
            out.write(trace.toString().getBytes("UTF-8")); out.close();
        } catch (Exception ignored) { }
    }
    synchronized void diagnostic() {
        // Counts and error class only: no query, URL, track, voice or credentials.
        try {
            java.io.FileOutputStream out = openFileOutput("station-soundcloud.json", MODE_PRIVATE);
            out.write(("{\"started\":"+started+",\"completed\":"+completed+",\"controls\":"+controls+",\"failures\":"+failures+",\"error\":\""+error+"\"}").getBytes("UTF-8")); out.close();
            if(error.length()==0)new java.io.File(getFilesDir(),"station-soundcloud-error.txt").delete();
        } catch (Exception ignored) { }
    }
    @Override public void onDestroy() { generation++; worker.shutdownNow(); main.removeCallbacksAndMessages(null); if (bound) unbindService(connection); super.onDestroy(); }
}
