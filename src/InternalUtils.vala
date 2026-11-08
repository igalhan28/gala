/*
 * Copyright 2012 Tom Beckmann
 * Copyright 2012 Rico Tzschichholz
 * Copyright 2023-2025 elementary, Inc. <https://elementary.io>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace Gala {
    public class InternalUtils {
        /**
         * Inserts a workspace at the given index. To ensure the workspace is not immediately
         * removed again when in dynamic workspaces, the window is first placed on it.
         *
         * @param index  The index at which to insert the workspace
         * @param new_window A window that should be moved to the new workspace
         */
        public static void insert_workspace_with_window (int index, Meta.Window new_window) {
            unowned WorkspaceManager workspace_manager = WorkspaceManager.get_default ();
            workspace_manager.freeze_remove ();

            new_window.change_workspace_by_index (index, false);

#if HAS_MUTTER48
            unowned List<Meta.WindowActor> actors = new_window.get_display ().get_compositor ().get_window_actors ();
#else
            unowned List<Meta.WindowActor> actors = new_window.get_display ().get_window_actors ();
#endif
            foreach (unowned Meta.WindowActor actor in actors) {
                if (actor.is_destroyed ())
                    continue;

                unowned Meta.Window window = actor.get_meta_window ();
                if (window == new_window)
                    continue;

                var current_index = window.get_workspace ().index ();
                if (current_index >= index
                    && !window.on_all_workspaces) {
                    window.change_workspace_by_index (current_index + 1, true);
                }
            }

            workspace_manager.thaw_remove ();
        }

        public static Clutter.ActorBox actor_box_from_rect (float x, float y, float width, float height) {
            var actor_box = Clutter.ActorBox ();
            actor_box.init_rect (x, y, width, height);
            Clutter.ActorBox.clamp_to_pixel (ref actor_box);

            return actor_box;
        }

        public delegate void WindowActorReadyCallback (Meta.WindowActor window_actor);

        public static void wait_for_window_actor (Meta.Window window, owned WindowActorReadyCallback callback) {
            unowned var window_actor = (Meta.WindowActor) window.get_compositor_private ();
            if (window_actor != null) {
                callback (window_actor);
                return;
            }

            Idle.add (() => {
                window_actor = (Meta.WindowActor) window.get_compositor_private ();

                if (window_actor != null) {
                    callback (window_actor);
                }

                return Source.REMOVE;
            });
        }

        public static void wait_for_window_actor_visible (Meta.Window window, owned WindowActorReadyCallback callback) {
            wait_for_window_actor (window, (window_actor) => {
                if (window_actor.visible) {
                    callback (window_actor);
                } else {
                    ulong show_handler = 0;
                    show_handler = window_actor.show.connect (() => {
                        window_actor.disconnect (show_handler);
                        callback (window_actor);
                    });
                }
            });
        }

        public static void clutter_actor_reparent (Clutter.Actor actor, Clutter.Actor new_parent) {
            if (actor == new_parent) {
                return;
            }

            actor.ref ();
            actor.get_parent ().remove_child (actor);
            new_parent.add_child (actor);
            actor.unref ();
        }

        public static void bell_notify (Meta.Display display) {
#if HAS_MUTTER48
            display.get_compositor ().get_stage ().context.get_backend ().get_default_seat ().bell_notify ();
#elif HAS_MUTTER47
            display.get_stage ().context.get_backend ().get_default_seat ().bell_notify ();
#else
            Clutter.get_default_backend ().get_default_seat ().bell_notify ();
#endif
        }

        /**
         * Returns the most recently used "normal" window (as gotten via {@link get_window_is_normal}) in the given workspace.
         * If there is a not normal but more recent window (e.g. a menu/tooltip) any_window will be set to that window otherwise
         * it will be set to the same window that is returned.
         */
        public static Meta.Window? get_mru_window (Meta.Workspace workspace, out Meta.Window? any_window = null) {
            any_window = null;

            var list = workspace.list_windows ();

            if (list.is_empty ()) {
                return null;
            }

            list.sort ((a, b) => {
                return (int) b.get_user_time () - (int) a.get_user_time ();
            });

            foreach (var window in list) {
                if (window.find_root_ancestor ().window_type == DOCK) {
                    continue;
                }

                if (any_window == null) {
                    any_window = window;
                }

                if (!Utils.get_window_is_normal (window)) {
                    continue;
                }

                return window;
            }

            return null;
        }

        private const string WINGPANEL_SCHEMA = "io.elementary.desktop.wingpanel";
        private const string NOTCH_HEIGHT_KEY = "notch-height";

        private static GLib.Settings? wingpanel_settings = null;
        private static bool wingpanel_settings_looked_up = false;

        /**
         * Returns the wingpanel settings if they are installed and provide the
         * notch-height key, null otherwise. Use it to get notified about notch changes.
         */
        public static unowned GLib.Settings? get_notch_settings () {
            if (!wingpanel_settings_looked_up) {
                wingpanel_settings_looked_up = true;

                unowned var source = SettingsSchemaSource.get_default ();
                var schema = source != null ? source.lookup (WINGPANEL_SCHEMA, true) : null;
                if (schema != null && schema.has_key (NOTCH_HEIGHT_KEY)) {
                    wingpanel_settings = new GLib.Settings.full (schema, null, null);
                }
            }

            return wingpanel_settings;
        }

        /**
         * Returns the height of the display notch (e.g. on Apple Silicon MacBooks) of the given
         * monitor in stage coordinates, or 0 if the monitor has no notch.
         *
         * The notch height is the one configured for wingpanel and only applies to the builtin panel.
         */
        public static int get_notch_height (Meta.Display display, int monitor) {
            unowned var settings = get_notch_settings ();
            if (settings == null) {
                return 0;
            }

            var height = settings.get_int (NOTCH_HEIGHT_KEY);
            if (height <= 0) {
                return 0;
            }

            unowned var monitor_manager = display.get_context ().get_backend ().get_monitor_manager ();
            foreach (unowned var logical_monitor in monitor_manager.get_logical_monitors ()) {
                if (logical_monitor.get_number () != monitor) {
                    continue;
                }

                foreach (unowned var physical_monitor in logical_monitor.get_monitors ()) {
                    if (physical_monitor.is_builtin ()) {
                        return Utils.scale_to_int (height, Utils.get_ui_scaling_factor (display, monitor));
                    }
                }
            }

            return 0;
        }
    }
}
