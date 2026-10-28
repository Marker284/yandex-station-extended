/* SPDX-License-Identifier: GPL-3.0-or-later */
package org.schabi.newpipe.station;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Signature-protected entry point. No screen, microphone or new network client. */
public final class StationSoundCloudReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        Intent service = new Intent(context, StationSoundCloudService.class);
        service.putExtra("command", intent.getStringExtra("command"));
        service.putExtra("query", intent.getStringExtra("query"));
        service.putExtra("seconds", intent.getLongExtra("seconds", 0));
        context.startService(service);
    }
}
