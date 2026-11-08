/*
 * Copyright 2026 elementary, Inc. (https://elementary.io)
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#if HAS_MUTTER50
/**
 * Handles the screen brightness keys (XF86MonBrightnessUp/Down).
 * Since GNOME 49 gnome-settings-daemon no longer handles these keys,
 * the compositor is expected to do so.
 */
public class Gala.BrightnessKeys : Object {
    private const string NOTIFICATION_COMPONENT_NAME = "BrightnessKeys";
    private const double STEP = 0.05;

    public Meta.Display display { private get; construct; }
    public BrightnessManager brightness_manager { private get; construct; }
    public NotificationsManager notifications_manager { private get; construct; }

    public BrightnessKeys (Meta.Display display, BrightnessManager brightness_manager, NotificationsManager notifications_manager) {
        Object (display: display, brightness_manager: brightness_manager, notifications_manager: notifications_manager);
    }

    construct {
        var schema = new GLib.Settings ("io.elementary.desktop.wm.keybindings");
        display.add_keybinding ("screen-brightness-up", schema, NONE, (display, window, event, binding) => step (1));
        display.add_keybinding ("screen-brightness-down", schema, NONE, (display, window, event, binding) => step (-1));
    }

    private void step (int direction) {
        double current;
        try {
            if (brightness_manager.get_n_monitors () == 0) {
                return;
            }

            current = brightness_manager.get_global_brightness ();
        } catch (Error e) {
            warning ("Failed to get brightness: %s", e.message);
            return;
        }

        /* Snap to the step grid so repeated presses land on round values */
        var new_value = (Math.round (current / STEP) + direction) * STEP;
        new_value = new_value.clamp (0.0, 1.0);

        try {
            brightness_manager.set_global_brightness (new_value);
        } catch (Error e) {
            warning ("Failed to set brightness: %s", e.message);
            return;
        }

        var hints = new GLib.HashTable<string, Variant> (null, null);
        hints.set ("x-canonical-private-synchronous", new Variant.string ("gala-feedback"));
        hints.set ("value", new Variant.int32 ((int) Math.round (new_value * 100)));

        notifications_manager.send.begin (
            NOTIFICATION_COMPONENT_NAME,
            "display-brightness-symbolic",
            "",
            "",
            {},
            hints
        );
    }
}
#endif
