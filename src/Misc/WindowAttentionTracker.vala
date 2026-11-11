/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2024 elementary, Inc. (https://elementary.io)
 */

public class Gala.WindowAttentionTracker : GLib.Object {
    /**
     * Attention requests arriving this soon after a workspace switch don't switch the workspace,
     * since they are almost always a client reacting to losing focus because of that switch.
     */
    private const int64 SWITCH_GRACE_PERIOD_US = 1000 * 1000;

    private static unowned WindowManager wm;
    private static int64 last_workspace_switch = 0;

    public static void init (WindowManager _wm) {
        wm = _wm;

        unowned var display = wm.get_display ();
        display.window_demands_attention.connect (on_window_demands_attention);
        display.window_marked_urgent.connect (on_window_demands_attention);

        display.get_workspace_manager ().workspace_switched.connect (() => {
            last_workspace_switch = GLib.get_monotonic_time ();
        });
    }

    private static void on_window_demands_attention (Meta.Window window) {
        /*
         * While gala is modal (e.g. during the workspace switch animation or in the multitasking view)
         * it keeps the input focus unset. Some clients (e.g. Electron apps) answer losing focus by
         * requesting activation, which mutter turns into "demands attention". Focusing them here would
         * get the focus unset again, resulting in a loop that keeps pulling the user back to that window's
         * workspace. The default window is focused anyway once the modal ends.
         */
        if (wm.is_modal ()) {
            return;
        }

        unowned var workspace = window.get_workspace ();
        if (workspace == null) {
            return;
        }

        unowned var active_workspace = window.display.get_workspace_manager ().get_active_workspace ();
        if (workspace != active_workspace &&
            GLib.get_monotonic_time () - last_workspace_switch < SWITCH_GRACE_PERIOD_US
        ) {
            return;
        }

        window.raise ();
        workspace.activate_with_focus (window, window.display.get_current_time ());
    }
}
