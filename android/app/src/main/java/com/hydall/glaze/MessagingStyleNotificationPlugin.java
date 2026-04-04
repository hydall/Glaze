package com.hydall.glaze;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;
import android.util.Base64;

import androidx.core.app.NotificationCompat;
import androidx.core.app.Person;
import androidx.core.graphics.drawable.IconCompat;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "MessagingStyleNotification")
public class MessagingStyleNotificationPlugin extends Plugin {

    private static final String CHANNEL_ID = "sc_message_channel";

    @Override
    protected void handleOnNewIntent(Intent intent) {
        super.handleOnNewIntent(intent);
        if (intent.hasExtra("custom_notification_charId")) {
            JSObject data = new JSObject();
            data.put("charId", intent.getStringExtra("custom_notification_charId"));
            if (intent.hasExtra("custom_notification_sessionId")) {
                data.put("sessionId", intent.getStringExtra("custom_notification_sessionId"));
            }
            if (intent.hasExtra("custom_notification_msgId")) {
                data.put("msgId", intent.getStringExtra("custom_notification_msgId"));
            }
            notifyListeners("notificationActionPerformed", data);
        }
    }

    @PluginMethod
    public void showMessagingNotification(PluginCall call) {
        String title = call.getString("title");
        String body = call.getString("body");
        String avatarBase64 = call.getString("avatarBase64");
        String charId = call.getString("charId");
        String sessionId = call.getString("sessionId");
        String msgId = call.getString("msgId");

        Context context = getContext();
        NotificationManager notificationManager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(CHANNEL_ID, "New Messages", NotificationManager.IMPORTANCE_HIGH);
            notificationManager.createNotificationChannel(channel);
        }

        Bitmap avatarBitmap = null;
        if (avatarBase64 != null && !avatarBase64.isEmpty()) {
            try {
                if (avatarBase64.contains(",")) {
                    avatarBase64 = avatarBase64.substring(avatarBase64.indexOf(",") + 1);
                }
                byte[] decodedBytes = Base64.decode(avatarBase64, Base64.DEFAULT);
                avatarBitmap = BitmapFactory.decodeByteArray(decodedBytes, 0, decodedBytes.length);
            } catch (Exception e) {
                e.printStackTrace();
            }
        }

        Person.Builder personBuilder = new Person.Builder().setName(title);
        if (avatarBitmap != null) {
            personBuilder.setIcon(IconCompat.createWithBitmap(avatarBitmap));
        }
        Person sender = personBuilder.build();

        NotificationCompat.MessagingStyle messagingStyle = new NotificationCompat.MessagingStyle(sender)
                .addMessage(body, System.currentTimeMillis(), sender);

        Intent intent = new Intent(context, getActivity().getClass());
        intent.setAction(Intent.ACTION_MAIN);
        intent.addCategory(Intent.CATEGORY_LAUNCHER);
        intent.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        intent.putExtra("custom_notification_charId", charId);
        if (sessionId != null) intent.putExtra("custom_notification_sessionId", sessionId);
        if (msgId != null) intent.putExtra("custom_notification_msgId", msgId);

        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }

        PendingIntent pendingIntent = PendingIntent.getActivity(
                context,
                charId != null ? charId.hashCode() : 0,
                intent,
                flags
        );

        int smallIconResId = context.getResources().getIdentifier("new_message", "drawable", context.getPackageName());
        if (smallIconResId == 0) smallIconResId = android.R.drawable.ic_dialog_info;

        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(smallIconResId)
                .setStyle(messagingStyle)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH);

        int notificationId = charId != null ? charId.hashCode() : (int) System.currentTimeMillis();
        notificationManager.notify(notificationId, builder.build());

        call.resolve();
    }

    @PluginMethod
    public void clearNotifications(PluginCall call) {
        String charId = call.getString("charId");
        if (charId != null) {
            NotificationManager notificationManager = (NotificationManager) getContext().getSystemService(Context.NOTIFICATION_SERVICE);
            notificationManager.cancel(charId.hashCode());
        }
        call.resolve();
    }
}
