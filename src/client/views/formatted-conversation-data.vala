/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

// Stores formatted data for a message.
public class FormattedConversationData : Object {
    private const string STYLE_EXAMPLE = "Gg"; // Use both upper and lower case to get max height.
    private const int LINE_SPACING = 4;
    private const int TEXT_LEFT = LINE_SPACING * 2 + IconFactory.UNREAD_ICON_SIZE;
    
    private const int FONT_SIZE_DATE = 11;
    private const int FONT_SIZE_SUBJECT = 9;
    private const int FONT_SIZE_FROM = 11;
    private const int FONT_SIZE_PREVIEW = 8;
    
    private static int cell_height = -1;
    private static int preview_height = -1;
    
    public bool is_unread { get; set; }
    public bool is_flagged { get; set; }
    public string date { get; private set; } 
    public string from { get; private set; }
    public string subject { get; private set; }
    public string? body { get; private set; default = null; } // optional
    public int num_emails { get; private set; }
    public Geary.Email? preview { get; private set; default = null; }
    
    // Creates a formatted message data from an e-mail.
    public FormattedConversationData(Geary.Conversation conversation, Geary.Email preview,
        Geary.Folder folder, string account_owner_email) {
        assert(preview.fields.fulfills(ConversationListStore.REQUIRED_FIELDS));
        
        // Load preview-related data.
        this.date = (preview.date != null)
            ? Date.pretty_print(preview.date.value, GearyApplication.instance.config.clock_format)
            : "";
        this.subject = get_clean_subject_as_string(preview);
        this.body = Geary.String.reduce_whitespace(preview.get_preview_as_string());
        this.preview = preview;
        
        // Load conversation-related data.
        this.is_unread = conversation.is_unread();
        this.is_flagged = conversation.is_flagged();
        this.from = get_authors(conversation, folder, account_owner_email);
        this.num_emails = conversation.get_count();
    }
    
    // Creates an example message (used interally for styling calculations.)
    public FormattedConversationData.create_example() {
        this.is_unread = false;
        this.is_flagged = false;
        this.date = STYLE_EXAMPLE;
        this.from = STYLE_EXAMPLE;
        this.subject = STYLE_EXAMPLE;
        this.body = STYLE_EXAMPLE + "\n" + STYLE_EXAMPLE;
        this.num_emails = 1;
    }
    
    private string get_authors(Geary.Conversation conversation, Geary.Folder? folder, string account_owner_email) {
        bool use_to = folder != null && folder.get_special_folder_type().is_outgoing();
        string normalized_account_owner_email = account_owner_email.normalize().casefold();
        Gee.Set<string> emails = new Gee.HashSet<string>();
        string[] authors = new string[0];
        
        foreach (Geary.Email message in conversation.get_emails(Geary.Conversation.Ordering.DATE_ASCENDING)) {
            Geary.RFC822.MailboxAddresses? addresses = use_to ? message.to : message.from;
            if (addresses == null || addresses.size < 1)
                continue;
            
            string normalized_address = addresses[0].address.normalize().casefold();
            if (!emails.add(normalized_address))
                continue;
            
            if (normalized_address == normalized_account_owner_email)
                authors += _("Me");
            else
                authors += addresses[0].get_short_address();
        }
        
        // If there is only one author, use their full name.
        if (authors.length == 1)
            return authors[0];
            
        StringBuilder authors_builder = new StringBuilder();
        foreach (string author in authors) {
            string[] tokens = author.strip().split(" ", 2);
            if (tokens.length < 1)
                continue;
            
            // TODO: Should we use a more sophisticated algorithm than "first word" to get the
            // first name?
            string first_name = tokens[0].strip();
            if (Geary.String.is_empty_or_whitespace(first_name))
                continue;
            
            if (authors_builder.len > 0)
                authors_builder.append(", ");
            authors_builder.append(first_name);
        }
        
        return authors_builder.str;
    }
    
    public string get_clean_subject_as_string(Geary.Email email) {
        string subject_string = email.get_subject_as_string();
        try {
            Regex subject_regex = new Regex("^(?i:Re:\\s*)+");
            subject_string = subject_regex.replace(subject_string, -1, 0, "");
        } catch (RegexError e) {
            debug("Failed to clean up subject line \"%s\": %s", subject_string, e.message);
        }
        
        return !Geary.String.is_empty_or_whitespace(subject_string) ? subject_string : _("(no subject)");
    }
    
    public void render(Cairo.Context ctx, Gtk.Widget widget, Gdk.Rectangle background_area, 
        Gdk.Rectangle cell_area, Gtk.CellRendererState flags) {
        render_internal(widget, cell_area, ctx, (flags & Gtk.CellRendererState.SELECTED) != 0);
    }
    
    // Call this on style changes.
    public void calculate_sizes(Gtk.Widget widget) {
        render_internal(widget, null, null, false, true);
    }
    
    // Must call calculate_sizes() first.
    public void get_size(Gtk.Widget widget, Gdk.Rectangle? cell_area, out int x_offset, 
        out int y_offset, out int width, out int height) {
        assert(cell_height != -1); // ensures calculate_sizes() was called.
        
        x_offset = 0;
        y_offset = 0;
        width = 0;
        height = cell_height;
    }
    
    // Can be used for rendering or calculating height.
    private void render_internal(Gtk.Widget widget, Gdk.Rectangle? cell_area = null, 
        Cairo.Context? ctx = null, bool selected, bool recalc_dims = false) {
        
        int y = LINE_SPACING + (cell_area != null ? cell_area.y : 0);
        
        // Date field.
        Pango.Rectangle ink_rect = render_date(widget, cell_area, ctx, y);

        // From field.
        ink_rect = render_from(widget, cell_area, ctx, y, ink_rect);
        y += ink_rect.height + ink_rect.y + LINE_SPACING;

        // If we are displaying a preview then the message counter goes on the same line as the
        // preview, otherwise it is with the subject.
        int preview_height = 0;
        if (GearyApplication.instance.config.display_preview) {
            // Subject field.
            render_subject(widget, cell_area, ctx, y);
            y += ink_rect.height + ink_rect.y + LINE_SPACING;
            
            // Number of e-mails field.
            int counter_width = render_counter(widget, cell_area, ctx, y);
            
            // Body preview.
            ink_rect = render_preview(widget, cell_area, ctx, y, selected, counter_width);
            preview_height = ink_rect.height + ink_rect.y + LINE_SPACING;
        } else {
            // Number of e-mails field.
            int counter_width = render_counter(widget, cell_area, ctx, y);

            // Subject field.
            render_subject(widget, cell_area, ctx, y, counter_width);
            y += ink_rect.height + ink_rect.y + LINE_SPACING;
        }

        if (recalc_dims) {
            FormattedConversationData.preview_height = preview_height;
            FormattedConversationData.cell_height = y + preview_height;
        } else {
            // Flagged indicator.
            if (is_flagged) {
                Gdk.cairo_set_source_pixbuf(ctx, IconFactory.instance.starred, cell_area.x + LINE_SPACING,
                    cell_area.y + LINE_SPACING);
                ctx.paint();
            } else {
                Gdk.cairo_set_source_pixbuf(ctx, IconFactory.instance.unstarred, cell_area.x + LINE_SPACING,
                    cell_area.y + LINE_SPACING);
                ctx.paint();
            }
            
            // Unread indicator.
            if (is_unread) {
                Gdk.cairo_set_source_pixbuf(ctx, IconFactory.instance.unread, cell_area.x + LINE_SPACING,
                    cell_area.y + (cell_area.height / 2) + LINE_SPACING);
                ctx.paint();
            }
        }
    }
    
    private Pango.Rectangle render_date(Gtk.Widget widget, Gdk.Rectangle? cell_area,
        Cairo.Context? ctx, int y) {

        Pango.Rectangle? ink_rect;
        Pango.Rectangle? logical_rect;
        Pango.FontDescription font_date = new Pango.FontDescription();
        font_date.set_size(FONT_SIZE_DATE * Pango.SCALE);
        Pango.AttrList list_date = new Pango.AttrList();
        list_date.insert(Pango.attr_foreground_new(10000, 10000, 55000)); // muted blue
        Pango.Layout layout_date = widget.create_pango_layout(null);
        layout_date.set_font_description(font_date);
        layout_date.set_attributes(list_date);
        layout_date.set_text(date, -1);
        layout_date.set_alignment(Pango.Alignment.RIGHT);
        layout_date.get_pixel_extents(out ink_rect, out logical_rect);
        if (ctx != null && cell_area != null) {
            ctx.move_to(cell_area.width - cell_area.x - ink_rect.width - ink_rect.x - LINE_SPACING, y);
            Pango.cairo_show_layout(ctx, layout_date);
        }
        return ink_rect;
    }
    
    private Pango.Rectangle render_from(Gtk.Widget widget, Gdk.Rectangle? cell_area,
        Cairo.Context? ctx, int y, Pango.Rectangle ink_rect) {

        Pango.FontDescription font_from = new Pango.FontDescription();
        font_from.set_size(FONT_SIZE_FROM * Pango.SCALE);
        font_from.set_weight(Pango.Weight.BOLD);
        Pango.Layout layout_from = widget.create_pango_layout(null);
        layout_from.set_font_description(font_from);
        layout_from.set_text(from, -1);
        layout_from.set_ellipsize(Pango.EllipsizeMode.END);
        if (ctx != null && cell_area != null) {
            layout_from.set_width((cell_area.width - ink_rect.width - ink_rect.x - LINE_SPACING -
                TEXT_LEFT)
            * Pango.SCALE);
            ctx.move_to(cell_area.x + TEXT_LEFT, y);
            Pango.cairo_show_layout(ctx, layout_from);
        }
        return ink_rect;
    }
    
    private int render_counter(Gtk.Widget widget, Gdk.Rectangle? cell_area, Cairo.Context? ctx, int y) {
        int num_email_width = 0;
        if (num_emails > 1) {
            Pango.Rectangle? ink_rect;
            Pango.Rectangle? logical_rect;
            string mails = 
                "<span background='#999999' foreground='white' size='x-small' weight='bold'> %d </span>"
                .printf(num_emails);
                
            Pango.Layout layout_num = widget.create_pango_layout(null);
            layout_num.set_markup(mails, -1);
            layout_num.set_alignment(Pango.Alignment.RIGHT);
            layout_num.get_pixel_extents(out ink_rect, out logical_rect);
            if (ctx != null && cell_area != null) {
                ctx.move_to(cell_area.width - cell_area.x - ink_rect.width - ink_rect.x - 
                    LINE_SPACING, y);
                Pango.cairo_show_layout(ctx, layout_num);
            }
            
            num_email_width = ink_rect.width + (LINE_SPACING * 3);
        }
        return num_email_width;
    }
    
    private void render_subject(Gtk.Widget widget, Gdk.Rectangle? cell_area, Cairo.Context? ctx,
        int y, int counter_width = 0) {

        Pango.FontDescription font_subject = new Pango.FontDescription();
        font_subject.set_size(FONT_SIZE_SUBJECT * Pango.SCALE);
        if (is_unread)
            font_subject.set_weight(Pango.Weight.BOLD);
        Pango.Layout layout_subject = widget.create_pango_layout(null);
        layout_subject.set_font_description(font_subject);
        layout_subject.set_text(subject, -1);
        if (cell_area != null)
            layout_subject.set_width((cell_area.width - TEXT_LEFT - counter_width) * Pango.SCALE);
        layout_subject.set_ellipsize(Pango.EllipsizeMode.END);
        if (ctx != null && cell_area != null) {
            ctx.move_to(cell_area.x + TEXT_LEFT, y);
            Pango.cairo_show_layout(ctx, layout_subject);
        }
    }
    
    private Pango.Rectangle render_preview(Gtk.Widget widget, Gdk.Rectangle? cell_area,
        Cairo.Context? ctx, int y, bool selected, int counter_width = 0) {

        Pango.FontDescription font_preview = new Pango.FontDescription();
        font_preview.set_size(FONT_SIZE_PREVIEW * Pango.SCALE);
        Pango.AttrList list_preview = new Pango.AttrList();

        uint16 shade = selected ? 0x3000 : 0x7000;
        list_preview.insert(Pango.attr_foreground_new(shade, shade, shade));
        
        Pango.Layout layout_preview = widget.create_pango_layout(null);
        layout_preview.set_font_description(font_preview);
        layout_preview.set_attributes(list_preview);
        
        layout_preview.set_text(body != null ? body : "\n\n", -1);
        layout_preview.set_wrap(Pango.WrapMode.WORD);
        layout_preview.set_ellipsize(Pango.EllipsizeMode.END);
        if (ctx != null && cell_area != null) {
            layout_preview.set_width((cell_area.width - TEXT_LEFT - counter_width) * Pango.SCALE);
            layout_preview.set_height(preview_height * Pango.SCALE);
            
            ctx.move_to(cell_area.x + TEXT_LEFT, y);
            Pango.cairo_show_layout(ctx, layout_preview);
        } else {
            layout_preview.set_width(int.MAX);
            layout_preview.set_height(int.MAX);
        }

        Pango.Rectangle? ink_rect;
        Pango.Rectangle? logical_rect;
        layout_preview.get_pixel_extents(out ink_rect, out logical_rect);
        return ink_rect;
    }
    
}

