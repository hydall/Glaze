import { Capacitor, registerPlugin } from '@capacitor/core';
import { logger } from '../../utils/logger.js';
import { ForegroundService } from '@capawesome-team/capacitor-android-foreground-service';
import { LocalNotifications } from '@capacitor/local-notifications';

const MessagingStyleNotification = registerPlugin('MessagingStyleNotification');

let pendingNotificationData = null;

function stableIdFromString(str) {
    let hash = 0;
    const s = String(str);
    for (let i = 0; i < s.length; i++) {
        hash = ((hash << 5) - hash) + s.charCodeAt(i);
        hash |= 0;
    }
    return (Math.abs(hash) % 2147483646) + 1; // 1..2147483646, never 0
}

if (Capacitor.getPlatform() === 'android') {
    LocalNotifications.addListener('localNotificationActionPerformed', (notification) => {
        logger.debug("[NotificationService] Action Performed:", JSON.stringify(notification));
        const data = notification.notification.extra;
        logger.debug("[NotificationService] Extra Data:", JSON.stringify(data));
        if (data && data.charId) {
            pendingNotificationData = data;
            logger.debug("[NotificationService] Dispatching open-chat for:", data);
            window.dispatchEvent(new CustomEvent('open-chat', { detail: data }));
        }
    });

    MessagingStyleNotification.addListener('notificationActionPerformed', (data) => {
        logger.debug("[MessagingStyleNotificationPlugin] Action Performed:", JSON.stringify(data));
        if (data && data.charId) {
            pendingNotificationData = data;
            logger.debug("[MessagingStyleNotificationPlugin] Dispatching open-chat for:", data);
            window.dispatchEvent(new CustomEvent('open-chat', { detail: data }));
        }
    });
}

async function createMessageNotificationChannel() {
    if (Capacitor.getPlatform() !== 'android') return;
    try {
        await LocalNotifications.createChannel({
            id: 'sc_message_channel',
            name: 'New Messages',
            description: 'Notifications for new messages',
            importance: 4, // Importance.High (sound and heads-up notification)
            visibility: 1,
            vibration: true
        });
    } catch (e) {
        console.warn("Error creating message channel:", e);
    }
}

export async function requestNotificationPermission() {
    try {
        if (Capacitor.getPlatform() === 'android') {
            const result = await LocalNotifications.requestPermissions();
            if (result.display === 'granted') {
                await createMessageNotificationChannel();
                return true;
            }
            return false;
        } else if (window.Notification) {
            const res = await Notification.requestPermission();
            return res === 'granted';
        }
    } catch (e) {
        console.error("Error requesting notification permission:", e);
    }
    return false;
}

export async function startGenerationNotification(title, body) {
    if (Capacitor.getPlatform() !== 'android') return;

    try {
        // 1. Create notification channel (if it doesn't exist yet)
        await ForegroundService.createNotificationChannel({
            id: 'sc_generation_channel',
            name: 'Generation Status',
            description: 'Shows when the app is generating text',
            importance: 1, // Importance.Min
            visibility: 1
        });

        // 2. Start the foreground service
        await ForegroundService.startForegroundService({
            id: 1001,
            title: title || 'Glaze',
            body: body || 'Generating...',
            smallIcon: 'ic_stat_icon_config_sample',
            silent: true,
            notificationChannelId: 'sc_generation_channel'
        });
    } catch (e) {
        console.warn("Android Foreground Service failed:", e);
    }
}

export async function stopGenerationNotification() {
    if (Capacitor.getPlatform() !== 'android') return;

    try {
        await ForegroundService.stopForegroundService();
    } catch (e) {
        console.warn("Failed to stop foreground service:", e);
    }
}

export function checkAndRequestNotifications() {
    if (Capacitor.getPlatform() === 'android') {
        // Always ensure channel exists on Android (window.Notification may not exist in WebView)
        createMessageNotificationChannel();
    } else if (window.Notification && Notification.permission === 'granted') {
        // Web: no channels needed, permission check only
    }
}

export async function clearMessageNotifications(charId) {
    if (Capacitor.getPlatform() !== 'android') return;

    try {
        await MessagingStyleNotification.clearNotifications({ charId: String(charId) });

        const delivered = await LocalNotifications.getDeliveredNotifications();
        const toRemove = delivered.notifications
            .filter(n => {
                // On Android, use group field (set to charId when scheduling)
                if (n.group && String(n.group) === String(charId)) return true;
                // Fallback: check extra (iOS) or data
                const extra = n.extra || n.data;
                return extra && String(extra.charId) === String(charId);
            })
            .map(n => ({ id: n.id, tag: n.tag }));

        if (toRemove.length > 0) {
            await LocalNotifications.removeDeliveredNotifications({ notifications: toRemove });
        }
    } catch (e) {
        console.warn("Error clearing notifications:", e);
    }
}

export function consumePendingNotificationData() {
    const data = pendingNotificationData;
    pendingNotificationData = null;
    return data;
}

export async function sendMessageNotification(title, body, icon, charId, sessionId, msgId) {
    // Don't notify if app is open and visible
    if (document.visibilityState === 'visible') return;

    logger.debug("[NotificationService] Sending notification for charId:", charId);

    if (!charId) {
        console.warn("[NotificationService] Warning: charId is missing/undefined!");
    }

    try {
        if (Capacitor.getPlatform() === 'android') {
            let avatarBase64 = null;
            if (icon) {
                let url = icon;
                if (!url.startsWith('http') && !url.startsWith('data:') && !url.startsWith('blob:')) {
                    url = `/characters/${url}`;
                }
                try {
                    const res = await fetch(url);
                    const blob = await res.blob();
                    await new Promise((resolve) => {
                        const reader = new FileReader();
                        reader.onloadend = () => {
                            avatarBase64 = reader.result;
                            resolve();
                        };
                        reader.readAsDataURL(blob);
                    });
                } catch (e) { console.warn("Failed to convert avatar to base64", e); }
            }

            await MessagingStyleNotification.showMessagingNotification({
                title,
                body,
                avatarBase64,
                charId: String(charId || ''),
                sessionId: String(sessionId || ''),
                msgId: String(msgId || '')
            });
        } else if (window.Notification && Notification.permission === 'granted') {
            let iconPath = icon;
            if (iconPath && !iconPath.startsWith('http') && !iconPath.startsWith('data:') && !iconPath.startsWith('blob:')) {
                iconPath = `/characters/${iconPath}`;
            }

            const n = new Notification(title, {
                body: body,
                icon: iconPath,
                data: { charId, sessionId, msgId }
            });
            n.onclick = () => {
                window.focus();
                if (charId) window.dispatchEvent(new CustomEvent('open-chat', { detail: { charId, sessionId, msgId } }));
                n.close();
            };
        }
    } catch (e) {
        console.error("Error sending notification:", e);
    }
}