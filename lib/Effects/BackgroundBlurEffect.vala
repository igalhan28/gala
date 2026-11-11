/*
 * Copyright 2025-2026 elementary, Inc. <https://elementary.io>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

public class Gala.BackgroundBlurEffect : Clutter.Effect {
    private const float MIN_DOWNSCALE_SIZE = 256.0f;
    private const float MAX_RADIUS = 12.0f;

    public float blur_radius { get; construct; }
    public float clip_radius { get; construct; }
    public float monitor_scale { get; construct set; }

    private float real_blur_radius;
    private float downscale_factor;

    private int texture_width;
    private int texture_height;

    private Cogl.Framebuffer background_framebuffer;
    private Cogl.Pipeline? background_pipeline;
    private Cogl.Texture background_texture;

    private Cogl.Framebuffer round_framebuffer;
    private Cogl.Pipeline? round_pipeline;
    private Cogl.Texture round_texture;
    private int round_clip_radius_location;
    private int round_actor_size_location;

    private float last_box_scale_factor = 1.0f;

    /* Re-blurring is expensive: it copies the stage framebuffer while it is
     * still being drawn (which forces tile-based GPUs like Apple's AGX to
     * flush and reload the whole render target), allocates three offscreen
     * textures and runs several render passes. So the blurred result is kept
     * and only recomputed when a paint redraws the whole actor. Paints that
     * only touch part of the actor reuse it and queue a full repaint for the
     * next frame. Re-blurring on such partial paints would also copy pixels
     * outside the redraw clip, which still contain last frame's output
     * including our own blurred background.
     */
    private bool cache_valid = false;
    private bool repaint_requested = false;
    private Clutter.ActorBox cached_box = {};
    private float cached_blur_radius = 0.0f;

    public BackgroundBlurEffect (float blur_radius, float clip_radius, float monitor_scale) {
        Object (blur_radius: blur_radius, clip_radius: clip_radius, monitor_scale: monitor_scale);
    }

    public override void set_actor (Clutter.Actor? new_actor) {
        if (actor != null) {
            actor.notify["width"].disconnect (update_actor_size);
            actor.notify["height"].disconnect (update_actor_size);
        }

        base.set_actor (new_actor);

        cache_valid = false;

        if (actor != null) {
            actor.notify["width"].connect (update_actor_size);
            actor.notify["height"].connect (update_actor_size);
            construct_pipelines ();
            update_actor_size ();
        } else {
            background_pipeline = null;
            round_pipeline = null;
        }
    }

    private void construct_pipelines () {
#if HAS_MUTTER47
        unowned var ctx = actor.context.get_backend ().get_cogl_context ();
#else
        unowned var ctx = Clutter.get_default_backend ().get_cogl_context ();
#endif

        background_pipeline = new Cogl.Pipeline (ctx);
        background_pipeline.set_layer_null_texture (0);
        background_pipeline.set_layer_filters (0, Cogl.PipelineFilter.LINEAR, Cogl.PipelineFilter.LINEAR);
        background_pipeline.set_layer_wrap_mode (0, Cogl.PipelineWrapMode.CLAMP_TO_EDGE);

        round_pipeline = new Cogl.Pipeline (ctx);
        round_pipeline.set_layer_null_texture (0);
        round_pipeline.set_layer_filters (0, Cogl.PipelineFilter.LINEAR, Cogl.PipelineFilter.LINEAR);
        round_pipeline.set_layer_wrap_mode (0, Cogl.PipelineWrapMode.CLAMP_TO_EDGE);
        round_pipeline.add_snippet (
            new Cogl.Snippet (
                Cogl.SnippetHook.FRAGMENT,
                """
                uniform sampler2D tex;
                uniform vec2 actor_size;
                uniform float clip_radius;

                float rounded_rect_coverage (vec2 p) {
                    float center_left = clip_radius;
                    float center_right = actor_size.x - clip_radius;

                    float center_x;
                    if (p.x < center_left) {
                        center_x = center_left;
                    } else if (p.x > center_right) {
                        center_x = center_right;
                    } else {
                        return 1.0;
                    }

                    float center_top = clip_radius;
                    float center_bottom = actor_size.y - clip_radius;

                    float center_y;
                    if (p.y < center_top) {
                        center_y = center_top;
                    } else if (p.y > center_bottom) {
                        center_y = center_bottom;
                    } else {
                        return 1.0;
                    }

                    vec2 delta = p - vec2 (center_x, center_y);
                    float dist_squared = dot (delta, delta);

                    // Fully outside the circle
                    float outer_radius = clip_radius + 0.5;
                    if (dist_squared >= (outer_radius * outer_radius)) {
                        return 0.0;
                    }

                    // Fully inside the circle
                    float inner_radius = clip_radius - 0.5;
                    if (dist_squared <= (inner_radius * inner_radius)) {
                        return 1.0;
                    }
                    // Only pixels on the edge of the curve need expensive antialiasing
                    return smoothstep (outer_radius, inner_radius, sqrt (dist_squared));
                }
                """,

                """
                vec4 sample = texture2D (tex, cogl_tex_coord0_in.xy);
                vec2 texture_coord = cogl_tex_coord0_in.xy * actor_size;
                float res = rounded_rect_coverage (texture_coord);
                cogl_color_out = sample * cogl_color_in * res;
                """
            )
        );

        round_clip_radius_location = round_pipeline.get_uniform_location ("clip_radius");
        round_actor_size_location = round_pipeline.get_uniform_location ("actor_size");

        update_clip_radius ();

        notify["monitor-scale"].connect (update_clip_radius);
    }

    private void update_clip_radius () {
        float[] _clip_radius = { clip_radius * monitor_scale };
        round_pipeline.set_uniform_float (round_clip_radius_location, 1, 1, _clip_radius);
    }

    private void update_actor_size () {
        float[] actor_size = {
            actor.width,
            actor.height
        };

        round_pipeline.set_uniform_float (round_actor_size_location, 2, 1, actor_size);
    }

    private void update_actor_box (Clutter.PaintContext paint_context, ref Clutter.ActorBox source_actor_box) {
        float box_scale_factor = 1.0f;
        float origin_x, origin_y;
        float width, height;

        var stage_view = paint_context.get_stage_view ();

        actor.get_transformed_position (out origin_x, out origin_y);
        actor.get_transformed_size (out width, out height);

        if (stage_view != null) {
            Mtk.Rectangle stage_view_layout = {};

            box_scale_factor = stage_view.get_scale ();
            last_box_scale_factor = box_scale_factor;

            stage_view.get_layout (ref stage_view_layout);

            origin_x -= stage_view_layout.x;
            origin_y -= stage_view_layout.y;
        } else {
            /* We're drawing off stage, e.g. during a screenshot.
             * Use last_box_scale_factor as it's probably the most accurate one.
             */
            box_scale_factor = last_box_scale_factor;
        }

        source_actor_box.set_origin (origin_x, origin_y);
        source_actor_box.set_size (width, height);

        source_actor_box.scale (box_scale_factor);

        Clutter.ActorBox.clamp_to_pixel (ref source_actor_box);
    }

    private float calculate_downscale_factor (float width, float height, float radius) {
        float downscale_factor = 1.0f;
        float scaled_width = width;
        float scaled_height = height;
        float scaled_radius = radius;

        /* This is the algorithm used by Firefox; keep downscaling until either the
         * blur radius is lower than the threshold, or the downscaled texture is too
         * small.
         */
        while (
            scaled_radius > MAX_RADIUS &&
            scaled_width > MIN_DOWNSCALE_SIZE &&
            scaled_height > MIN_DOWNSCALE_SIZE
        ) {
            downscale_factor *= 2.0f;

            scaled_width = width / downscale_factor;
            scaled_height = height / downscale_factor;
            scaled_radius = radius / downscale_factor;
        }

        return downscale_factor;
    }

    private void setup_projection_matrix (Cogl.Framebuffer framebuffer, float width, float height) {
        Graphene.Matrix projection = {};
        projection.init_translate ({ -width / 2.0f, -height / 2.0f, 0.0f });
        projection.scale (2.0f / width, -2.0f / height, 1.0f);

        framebuffer.set_projection_matrix (projection);
    }

    private bool update_rounded_fbo (int width, int height, float downscale_factor) {
        if (
            texture_width == width &&
            texture_height == height &&
            this.downscale_factor == downscale_factor &&
            round_framebuffer != null
        ) {
            return true;
        }

#if HAS_MUTTER47
        unowned var ctx = actor.context.get_backend ().get_cogl_context ();
#else
        unowned var ctx = Clutter.get_default_backend ().get_cogl_context ();
#endif

        var new_width = (int) Math.floorf (width / downscale_factor);
        var new_height = (int) Math.floorf (height / downscale_factor);

        round_texture = new Cogl.Texture2D.with_size (ctx, new_width, new_height);
        round_pipeline.set_layer_texture (0, round_texture);
        round_framebuffer = new Cogl.Offscreen.with_texture (round_texture);
        cache_valid = false;

        setup_projection_matrix (round_framebuffer, new_width, new_height);

        return true;
    }

    private bool update_background_fbo (int width, int height) {
        if (
            texture_width == width &&
            texture_height == height &&
            background_framebuffer != null
        ) {
            return true;
        }

#if HAS_MUTTER47
        unowned var ctx = actor.context.get_backend ().get_cogl_context ();
#else
        unowned var ctx = Clutter.get_default_backend ().get_cogl_context ();
#endif

        background_texture = new Cogl.Texture2D.with_size (ctx, width, height);

        background_pipeline.set_layer_texture (0, background_texture);
        background_framebuffer = new Cogl.Offscreen.with_texture (background_texture);

        setup_projection_matrix (background_framebuffer, width, height);

        return true;
    }

    private bool update_framebuffers (Clutter.PaintContext paint_context, Clutter.ActorBox actor_box) {
        var width = (int) actor_box.get_width ();
        var height = (int) actor_box.get_height ();

        if (width <= 0 || height <= 0) {
            warning ("BackgroundBlurEffect: Couldn't update framebuffers, incorrect size");
            return false;
        }

        var downscale_factor = calculate_downscale_factor (width, height, real_blur_radius);

        var updated = update_rounded_fbo (width, height, downscale_factor) && update_background_fbo (width, height);

        texture_width = width;
        texture_height = height;
        this.downscale_factor = downscale_factor;

        return updated;
    }

    private Clutter.PaintNode create_blur_nodes (Clutter.PaintNode node) {
        float width, height;
        actor.get_size (out width, out height);

        var blur_node = new Clutter.BlurNode (
            (uint) (texture_width / downscale_factor),
            (uint) (texture_height / downscale_factor),
            real_blur_radius / downscale_factor
        );
        blur_node.add_rectangle ({
            0.0f,
            0.0f,
            round_texture.get_width (),
            round_texture.get_height ()
        });

        var round_node = new Clutter.LayerNode.to_framebuffer (round_framebuffer, round_pipeline);
        round_node.add_child (blur_node);
        round_node.add_rectangle ({ 0.0f, 0.0f, width, height });

        node.add_child (round_node);

        return blur_node;
    }

    private void add_actor_node (Clutter.PaintNode node) {
        var actor_node = new Clutter.ActorNode (actor, -1);
        node.add_child (actor_node);
    }

    private void paint_background (Clutter.PaintNode node, Clutter.PaintContext paint_context, Clutter.ActorBox source_actor_box) {
        float transformed_x, transformed_y, transformed_width, transformed_height;

        source_actor_box.get_origin (out transformed_x, out transformed_y);
        source_actor_box.get_size (out transformed_width, out transformed_height);

        /* Background layer node */
        var background_node = new Clutter.LayerNode.to_framebuffer (background_framebuffer, background_pipeline);
        node.add_child (background_node);
        background_node.add_rectangle ({ 0.0f, 0.0f, texture_width / downscale_factor, texture_height / downscale_factor });

        /* Blit node */
        var blit_node = new Clutter.BlitNode (paint_context.get_framebuffer ());
        background_node.add_child (blit_node);
        blit_node.add_blit_rectangle (
            (int) transformed_x,
            (int) transformed_y,
            0, 0,
            (int) transformed_width,
            (int) transformed_height
        );
    }

    public override void paint_node (Clutter.PaintNode node, Clutter.PaintContext paint_context, Clutter.EffectPaintFlags flags) {
        if (blur_radius <= 0) {
            // fallback to drawing actor
            add_actor_node (node);
            return;
        }

        var total_scale = double.min (actor.scale_x, actor.scale_y);
        Clutter.Actor? parent = actor;
        while ((parent = parent.get_parent ()) != null) {
            total_scale *= double.min (parent.scale_x, parent.scale_y);
        }

        var relative_opacity = (float) actor.opacity / 255.0f;
        real_blur_radius = blur_radius * (float) Math.pow (relative_opacity, 2) * monitor_scale * (float) total_scale;

        Clutter.ActorBox source_actor_box = {};
        update_actor_box (paint_context, ref source_actor_box);

        /* Failing to create or update the offscreen framebuffers prevents
         * the entire effect to be applied.
         */
        if (!update_framebuffers (paint_context, source_actor_box)) {
            add_actor_node (node);
            return;
        }

        var on_stage = paint_context.get_stage_view () != null;

        if (on_stage && can_use_cached_blur (paint_context, source_actor_box)) {
            paint_cached_blur (node);

            // Make sure the next frame redraws the whole actor so it can re-blur
            repaint_requested = true;
            queue_repaint ();
        } else {
            repaint_requested = false;

            var blur_node = create_blur_nodes (node);
            paint_background (blur_node, paint_context, source_actor_box);

            /* Off-stage paints (screenshots, screencasts) blit from a different
             * framebuffer, so their result must not be reused on stage.
             */
            cache_valid = on_stage;
            cached_box = source_actor_box;
            cached_blur_radius = real_blur_radius;
        }

        add_actor_node (node);
    }

    /**
     * Whether we can paint the blur computed in an earlier frame instead of
     * recomputing it. That's the case when this paint only redraws part of the
     * actor, see the comment at the top.
     */
    private bool can_use_cached_blur (Clutter.PaintContext paint_context, Clutter.ActorBox source_actor_box) {
        if (!cache_valid ||
            !source_actor_box.equal (cached_box) ||
            real_blur_radius != cached_blur_radius
        ) {
            // Geometry, scale or opacity changed (e.g. the dock is sliding in): blur right away
            return false;
        }

        /* If the repaint we requested last time still didn't cover the whole
         * actor (e.g. it's partially offscreen or clipped), re-blur anyway
         * instead of requesting repaints forever.
         */
        if (repaint_requested) {
            return false;
        }

        return !clip_covers_rect (paint_context, get_actor_stage_rect (paint_context));
    }

    private Mtk.Rectangle get_actor_stage_rect (Clutter.PaintContext paint_context) {
        float x, y, width, height;
        actor.get_transformed_position (out x, out y);
        actor.get_transformed_size (out width, out height);

        // Round inwards, the redraw clip is in integer stage coordinates
        var x1 = (int) Math.ceilf (x);
        var y1 = (int) Math.ceilf (y);
        var x2 = (int) Math.floorf (x + width);
        var y2 = (int) Math.floorf (y + height);

        Mtk.Rectangle rect = { x1, y1, int.max (x2 - x1, 0), int.max (y2 - y1, 0) };

        // Parts outside of the view are never in its redraw clip
        Mtk.Rectangle view_rect = {};
        paint_context.get_stage_view ().get_layout (ref view_rect);

        Mtk.Rectangle intersection;
        if (!rect.intersect (view_rect, out intersection)) {
            return { 0, 0, 0, 0 };
        }

        return intersection;
    }

    private static bool clip_covers_rect (Clutter.PaintContext paint_context, Mtk.Rectangle rect) {
        unowned var redraw_clip = paint_context.get_redraw_clip ();
        if (redraw_clip == null || rect.width == 0 || rect.height == 0) {
            return true;
        }

        return redraw_clip.contains_rectangle (rect) == Mtk.RegionOverlap.IN;
    }

    private void paint_cached_blur (Clutter.PaintNode node) {
        float width, height;
        actor.get_size (out width, out height);

        var cached_node = new Clutter.PipelineNode (round_pipeline);
        cached_node.add_rectangle ({ 0.0f, 0.0f, width, height });
        node.add_child (cached_node);
    }
}
