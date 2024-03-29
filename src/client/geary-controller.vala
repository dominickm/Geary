/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

// Primary controller object for Geary.
public class GearyController {
    private class ListFoldersOperation : Geary.NonblockingBatchOperation {
        public Geary.Account account;
        public Geary.FolderPath path;
        
        public ListFoldersOperation(Geary.Account account, Geary.FolderPath path) {
            this.account = account;
            this.path = path;
        }
        
        public override async Object? execute_async(Cancellable? cancellable) throws Error {
            return yield account.list_folders_async(path, cancellable);
        }
    }
    
    private class FetchFolderOperation : Geary.NonblockingBatchOperation {
        public Geary.Account account;
        public Geary.FolderPath folder_path;
        
        public FetchFolderOperation(Geary.Account account, Geary.FolderPath folder_path) {
            this.account = account;
            this.folder_path = folder_path;
        }
        
        public override async Object? execute_async(Cancellable? cancellable) throws Error {
            return yield account.fetch_folder_async(folder_path);
        }
    }
    
    // Named actions.
    public const string ACTION_HELP = "GearyHelp";
    public const string ACTION_ABOUT = "GearyAbout";
    public const string ACTION_QUIT = "GearyQuit";
    public const string ACTION_NEW_MESSAGE = "GearyNewMessage";
    public const string ACTION_REPLY_TO_MESSAGE = "GearyReplyToMessage";
    public const string ACTION_REPLY_ALL_MESSAGE = "GearyReplyAllMessage";
    public const string ACTION_FORWARD_MESSAGE = "GearyForwardMessage";
    public const string ACTION_DELETE_MESSAGE = "GearyDeleteMessage";
    public const string ACTION_ZOOM_IN = "GearyZoomIn";
    public const string ACTION_ZOOM_OUT = "GearyZoomOut";
    public const string ACTION_ZOOM_NORMAL = "GearyZoomNormal";
    public const string ACTION_PREFERENCES = "GearyPreferences";
    public const string ACTION_MARK_AS_MENU = "GearyMarkAsMenuButton";
    public const string ACTION_MARK_AS_READ = "GearyMarkAsRead";
    public const string ACTION_MARK_AS_UNREAD = "GearyMarkAsUnread";
    public const string ACTION_MARK_AS_STARRED = "GearyMarkAsStarred";
    public const string ACTION_MARK_AS_UNSTARRED = "GearyMarkAsUnStarred";
    public const string ACTION_COPY_MENU = "GearyCopyMenuButton";
    public const string ACTION_MOVE_MENU = "GearyMoveMenuButton";

    public const int FETCH_EMAIL_CHUNK_COUNT = 50;
    
    private const string DELETE_MESSAGE_LABEL = _("_Delete");
    private const string DELETE_MESSAGE_TOOLTIP = null;
    private const string DELETE_MESSAGE_ICON_NAME = "user-trash-full";
    
    private const string ARCHIVE_MESSAGE_LABEL = _("_Archive");
    private const string ARCHIVE_MESSAGE_TOOLTIP = _("Archive the selected conversation");
    private const string ARCHIVE_MESSAGE_ICON_NAME = "mail-archive";
    
    public MainWindow main_window { get; private set; }
    
    private Geary.Account? account = null;
    private Cancellable cancellable_folder = new Cancellable();
    private Cancellable cancellable_inbox = new Cancellable();
    private Cancellable cancellable_message = new Cancellable();
    private Geary.Folder? current_folder = null;
    private Geary.Folder? inbox_folder = null;
    private Geary.ConversationMonitor? current_conversations = null;
    private Geary.ConversationMonitor? inbox_conversations = null;
    private int busy_count = 0;
    private Gee.Set<Geary.Conversation> selected_conversations = new Gee.HashSet<Geary.Conversation>();
    private Geary.Conversation? last_deleted_conversation = null;
    private Gee.LinkedList<ComposerWindow> composer_windows = new Gee.LinkedList<ComposerWindow>();
    private File? last_save_directory = null;
    private NewMessagesMonitor? new_messages_monitor = null;
    private NewMessagesIndicator? new_messages_indicator = null;
    private UnityLauncher? unity_launcher = null;
    private NotificationBubble? notification_bubble = null;
    
    public GearyController() {
        // Setup actions.
        GearyApplication.instance.actions.add_actions(create_actions(), this);
        GearyApplication.instance.ui_manager.insert_action_group(
            GearyApplication.instance.actions, 0);
        GearyApplication.instance.load_ui_file("accelerators.ui");
        
        // Listen for attempts to close the application.
        GearyApplication.instance.exiting.connect(on_application_exiting);
        
        // Create the main window (must be done after creating actions.)
        main_window = new MainWindow();
        
        enable_message_buttons(false);

        // Connect to various UI signals.
        main_window.conversation_list_view.conversations_selected.connect(on_conversations_selected);
        main_window.conversation_list_view.load_more.connect(on_load_more);
        main_window.conversation_list_view.mark_conversation.connect(on_mark_conversation);
        main_window.folder_list.folder_selected.connect(on_folder_selected);
        main_window.folder_list.copy_conversation.connect(on_copy_conversation);
        main_window.folder_list.move_conversation.connect(on_move_conversation);
        main_window.main_toolbar.copy_folder_menu.folder_selected.connect(on_copy_conversation);
        main_window.main_toolbar.move_folder_menu.folder_selected.connect(on_move_conversation);
        main_window.conversation_viewer.link_selected.connect(on_link_selected);
        main_window.conversation_viewer.reply_to_message.connect(on_reply_to_message);
        main_window.conversation_viewer.reply_all_message.connect(on_reply_all_message);
        main_window.conversation_viewer.forward_message.connect(on_forward_message);
        main_window.conversation_viewer.mark_message.connect(on_conversation_viewer_mark_message);
        main_window.conversation_viewer.open_attachment.connect(on_open_attachment);
        main_window.conversation_viewer.save_attachments.connect(on_save_attachments);

        main_window.conversation_list_view.grab_focus();
        
        set_busy(false);
        
        main_window.show_all();
    }
    
    ~GearyController() {
        assert(account == null);
    }

    private void add_accelerator(string accelerator, string action) {
        // Parse the accelerator.
        uint key = 0;
        Gdk.ModifierType modifiers = 0;
        Gtk.accelerator_parse(accelerator, out key, out modifiers);
        if (key == 0) {
            debug("Failed to parse accelerator '%s'", accelerator);
            return;
        }

        // Connect the accelerator to the action.
        GearyApplication.instance.ui_manager.get_accel_group().connect(key, modifiers,
            Gtk.AccelFlags.VISIBLE, (group, obj, key, modifiers) => {
                GearyApplication.instance.actions.get_action(action).activate();
                return false;
            });
    }

    private Gtk.ActionEntry[] create_actions() {
        Gtk.ActionEntry[] entries = new Gtk.ActionEntry[0];
        
        Gtk.ActionEntry prefs = { ACTION_PREFERENCES, Gtk.Stock.PREFERENCES, TRANSLATABLE, null,
            null, on_preferences };
        prefs.label = _("_Preferences");
        entries += prefs;

        Gtk.ActionEntry help = { ACTION_HELP, Gtk.Stock.HELP, TRANSLATABLE, "F1", null, on_help };
        help.label = _("_Help");
        entries += help;

        Gtk.ActionEntry about = { ACTION_ABOUT, Gtk.Stock.ABOUT, TRANSLATABLE, null, null, on_about };
        about.label = _("_About");
        entries += about;
        
        Gtk.ActionEntry quit = { ACTION_QUIT, Gtk.Stock.QUIT, TRANSLATABLE, "<Ctrl>Q", null, on_quit };
        quit.label = _("_Quit");
        entries += quit;
        
        Gtk.ActionEntry mark_menu = { ACTION_MARK_AS_MENU, null, TRANSLATABLE, null, null,
            on_show_mark_menu };
        mark_menu.label = _("_Mark as...");
        entries += mark_menu;

        Gtk.ActionEntry mark_read = { ACTION_MARK_AS_READ, "mail-mark-read", TRANSLATABLE, null, null,
            on_mark_as_read };
        mark_read.label = _("Mark as _read");
        entries += mark_read;

        Gtk.ActionEntry mark_unread = { ACTION_MARK_AS_UNREAD, "mail-mark-unread", TRANSLATABLE, null,
            null, on_mark_as_unread };
        mark_unread.label = _("Mark as _unread");
        entries += mark_unread;
        
        Gtk.ActionEntry mark_starred = { ACTION_MARK_AS_STARRED, "starred", TRANSLATABLE, null, null,
            on_mark_as_starred };
        mark_starred.label = _("_Star");
        entries += mark_starred;

        Gtk.ActionEntry mark_unstarred = { ACTION_MARK_AS_UNSTARRED, "non-starred", TRANSLATABLE, null,
            null, on_mark_as_unstarred };
        mark_unstarred.label = _("U_nstar");
        entries += mark_unstarred;

        Gtk.ActionEntry copy_menu = { ACTION_COPY_MENU, null, TRANSLATABLE, "L", null,
            on_show_copy_menu };
        copy_menu.label = _("_Label");
        entries += copy_menu;

        Gtk.ActionEntry move_menu = { ACTION_MOVE_MENU, null, TRANSLATABLE, "M", null,
            on_show_move_menu };
        move_menu.label = _("_Move");
        entries += move_menu;

        Gtk.ActionEntry new_message = { ACTION_NEW_MESSAGE, null, TRANSLATABLE, "<Ctrl>N", null,
            on_new_message };
        new_message.label = _("_New Message");
        entries += new_message;
        add_accelerator("N", ACTION_NEW_MESSAGE);

        Gtk.ActionEntry reply_to_message = { ACTION_REPLY_TO_MESSAGE, null, TRANSLATABLE, "<Ctrl>R",
            null, on_reply_to_message_action };
        entries += reply_to_message;
        add_accelerator("R", ACTION_REPLY_TO_MESSAGE);
        
        Gtk.ActionEntry reply_all_message = { ACTION_REPLY_ALL_MESSAGE, null, TRANSLATABLE,
            "<Ctrl><Shift>R", null, on_reply_all_message_action };
        entries += reply_all_message;
        add_accelerator("<Shift>R", ACTION_REPLY_ALL_MESSAGE);
        
        Gtk.ActionEntry forward_message = { ACTION_FORWARD_MESSAGE, null, TRANSLATABLE, "<Ctrl>L", null,
            on_forward_message_action };
        entries += forward_message;
        add_accelerator("F", ACTION_FORWARD_MESSAGE);
        
        Gtk.ActionEntry delete_message = { ACTION_DELETE_MESSAGE, "user-trash-full", TRANSLATABLE,
            "A", null, on_delete_message };
        entries += delete_message;
        add_accelerator("Delete", ACTION_DELETE_MESSAGE);
        add_accelerator("BackSpace", ACTION_DELETE_MESSAGE);

        Gtk.ActionEntry zoom_in = { ACTION_ZOOM_IN, null, null, "<Ctrl>equal",
            null, on_zoom_in };
        entries += zoom_in;
        add_accelerator("equal", ACTION_ZOOM_IN);

        Gtk.ActionEntry zoom_out = { ACTION_ZOOM_OUT, null, null, "<Ctrl>minus",
            null, on_zoom_out };
        entries += zoom_out;
        add_accelerator("minus", ACTION_ZOOM_OUT);

        Gtk.ActionEntry zoom_normal = { ACTION_ZOOM_NORMAL, null, null, "<Ctrl>0",
            null, on_zoom_normal };
        entries += zoom_normal;
        add_accelerator("0", ACTION_ZOOM_NORMAL);

        return entries;
    }
    
    public async void connect_account_async(Geary.Account? new_account, Cancellable? cancellable) {
        if (account == new_account)
            return;
        
        // Disconnect the old account, if any.
        if (account != null) {
            cancel_folder();
            cancel_inbox();
            cancel_message();
            
            account.folders_added_removed.disconnect(on_folders_added_removed);
            
            main_window.title = GearyApplication.NAME;
            main_window.conversation_list_store.account_owner_email = null;
            main_window.folder_list.remove_all_branches();
            
            if (inbox_conversations != null) {
                try {
                    yield inbox_conversations.stop_monitoring_async(true, cancellable);
                } catch (Error close_conversations_err) {
                    debug("Unable to stop monitoring inbox: %s", close_conversations_err.message);
                }
                
                inbox_conversations = null;
                inbox_folder = null;
            }
            
            if (inbox_folder != null) {
                try {
                    yield inbox_folder.close_async(cancellable);
                } catch (Error close_inbox_err) {
                    debug("Unable to close monitored inbox: %s", close_inbox_err.message);
                }
                
                inbox_folder = null;
            }
            
            try {
                yield account.close_async(cancellable);
            } catch (Error close_err) {
                debug("Unable to close account %s: %s", account.to_string(), close_err.message);
            }
        }
        
        account = new_account;
        
        // Connect the new account, if any.
        if (account != null) {
            try {
                yield account.open_async(cancellable);
            } catch (Error open_err) {
                // TODO: Better error reporting to user
                debug("Unable to open account %s: %s", account.to_string(), open_err.message);
                
                account = null;
                
                GearyApplication.instance.panic();
            }
            
            account.folders_added_removed.connect(on_folders_added_removed);
            account.email_sent.connect(on_sent);
            
            if (account.settings.service_provider == Geary.ServiceProvider.YAHOO)
                main_window.title = GearyApplication.NAME + "!";
            main_window.conversation_list_store.account_owner_email = account.settings.email.address;
            
            main_window.folder_list.set_user_folders_root_name(_("Labels"));
            load_folders.begin(cancellable_folder);
        }
    }
    
    public async void disconnect_account_async(Cancellable? cancellable) throws Error {
        yield connect_account_async(null, cancellable);
    }
    
    private bool is_viewed_conversation(Geary.Conversation? conversation) {
        return conversation != null && selected_conversations.size > 0 &&
            Geary.Collection.get_first<Geary.Conversation>(selected_conversations) == conversation;
    }
    
    // Update widgets and such to match capabilities of the current folder ... sensitivity is handled
    // by other utility methods
    private void update_ui() {
        Gtk.Action delete_message = GearyApplication.instance.actions.get_action(ACTION_DELETE_MESSAGE);
        if (current_folder is Geary.FolderSupportsArchive) {
            delete_message.label = ARCHIVE_MESSAGE_LABEL;
            delete_message.tooltip = ARCHIVE_MESSAGE_TOOLTIP;
            delete_message.icon_name = ARCHIVE_MESSAGE_ICON_NAME;
        } else {
            // even if not Geary.FolderSupportsrRemove, use delete icons and label, although they
            // may be insensitive the entire time
            delete_message.label = DELETE_MESSAGE_LABEL;
            delete_message.tooltip = DELETE_MESSAGE_TOOLTIP;
            delete_message.icon_name = DELETE_MESSAGE_ICON_NAME;
        }
    }
    
    private async void load_folders(Cancellable? cancellable) {
        try {
            // pull down the root-level user folders and recursively add to sidebar
            Gee.Collection<Geary.Folder> folders = yield account.list_folders_async(null);
            if (folders != null)
                on_folders_added_removed(folders, null);
            else
                debug("no folders");
        } catch (Error err) {
            message("%s", err.message);
        }
    }
    
    private void on_folder_selected(Geary.Folder? folder) {
        if (folder == null) {
            debug("no folder selected");
            return;
        }
        
        debug("Folder %s selected", folder.to_string());
        set_busy(true);
        do_select_folder.begin(folder, on_select_folder_completed);
    }
    
    private async void do_select_folder(Geary.Folder folder) throws Error {
        cancel_folder();
        
        Cancellable? conversation_cancellable = (current_folder != inbox_folder)
            ? cancellable_folder : cancellable_inbox;
        
        // stop monitoring for conversations and close the folder (but only if not the inbox_folder,
        // which we leave open for notifications)
        if (current_conversations != null) {
            yield current_conversations.stop_monitoring_async((current_folder != inbox_folder), null);
            current_conversations = null;
        } else if (current_folder != null && current_folder != inbox_folder) {
            yield current_folder.close_async();
        }
        
        if (folder != null)
            debug("switching to %s", folder.to_string());
        
        current_folder = folder;
        main_window.conversation_list_store.set_current_folder(current_folder, conversation_cancellable);
        
        // The current folder may be null if the user rapidly switches between folders. If they have
        // done that then this folder selection is invalid anyways, so just return.
        if (current_folder == null) {
            warning("Can not open folder: %s", folder.to_string());
            return;
        }
        
        update_ui();
        
        if (current_folder != inbox_folder) {
            current_conversations = new Geary.ConversationMonitor(current_folder, false,
                ConversationListStore.REQUIRED_FIELDS);
        } else {
            if (inbox_conversations == null) {
                inbox_conversations = new Geary.ConversationMonitor(inbox_folder, false,
                    ConversationListStore.REQUIRED_FIELDS);
            }
            
            current_conversations = inbox_conversations;
        }
        
        current_conversations.scan_started.connect(on_scan_started);
        current_conversations.scan_error.connect(on_scan_error);
        current_conversations.scan_completed.connect(on_scan_completed);
        current_conversations.conversation_appended.connect(on_conversation_appended);
        current_conversations.conversation_trimmed.connect(on_conversation_trimmed);
        current_conversations.email_flags_changed.connect(on_email_flags_changed);
        
        main_window.conversation_list_store.set_conversation_monitor(current_conversations);
        main_window.conversation_list_view.set_conversation_monitor(current_conversations);
        
        if (!current_conversations.is_monitoring)
            yield current_conversations.start_monitoring_async(FETCH_EMAIL_CHUNK_COUNT, conversation_cancellable);
    }
    
    private void on_scan_started() {
        set_busy(true);
    }
    
    private void on_scan_error(Error err) {
        set_busy(false);
    }
    
    private void on_scan_completed() {
        set_busy(false);
    }
    
    private void on_notification_bubble_invoked(Geary.Email? email) {
        if (email == null || inbox_folder == null)
            return;
        
        main_window.folder_list.select_path(inbox_folder.get_path());
        Geary.Conversation? conversation = current_conversations.get_conversation_for_email(email.id);
        if (conversation != null)
            main_window.conversation_list_view.select_conversation(conversation);
    }
    
    private void on_indicator_activated_application(uint32 timestamp) {
        main_window.present_with_time(timestamp);
    }
    
    private void on_indicator_activated_composer(uint32 timestamp) {
        main_window.present_with_time(timestamp);
        on_new_message();
    }
    
    private void on_indicator_activated_inbox(uint32 timestamp) {
        main_window.present_with_time(timestamp);
        
        // reset new messages
        new_messages_monitor.clear_new_messages();
        
        // attempt to select Inbox
        if (inbox_folder != null)
            main_window.folder_list.select_path(inbox_folder.get_path());
    }
    
    private void on_conversation_appended(Geary.Conversation conversation,
        Gee.Collection<Geary.Email> email) {
        if (is_viewed_conversation(conversation)) {
            do_show_message.begin(conversation.get_emails(Geary.Conversation.Ordering.NONE), cancellable_message,
                false, on_show_message_completed);
        }
    }
    
    private void on_conversation_trimmed(Geary.Conversation conversation, Geary.Email email) {
        if (is_viewed_conversation(conversation))
            main_window.conversation_viewer.remove_message(email);
    }
    
    private void on_load_more() {
        debug("on_load_more");
        Geary.EmailIdentifier? low_id = main_window.conversation_list_store.get_lowest_email_id();
        if (low_id == null)
            return;
        
        set_busy(true);
        current_conversations.load_by_id_async.begin(low_id, - FETCH_EMAIL_CHUNK_COUNT,
            Geary.Folder.ListFlags.EXCLUDING_ID, cancellable_folder, on_load_more_completed);
    }
    
    private void on_load_more_completed(Object? source, AsyncResult result) {
        debug("on load more completed");
        try {
            current_conversations.load_by_id_async.end(result);
        } catch (Error err) {
            debug("Error, unable to load conversations: %s", err.message);
        }
        
        set_busy(false);
    }
    
    private void on_email_flags_changed(Geary.Conversation conversation, Geary.Email email) {
        main_window.conversation_viewer.update_flags(email);
    }
    
    private void on_select_folder_completed(Object? source, AsyncResult result) {
        try {
            do_select_folder.end(result);
        } catch (Error err) {
            debug("Unable to select folder: %s", err.message);
        }
        
        set_busy(false);
    }
    
    private void on_conversations_selected(Gee.Set<Geary.Conversation> selected) {
        cancel_message();

        selected_conversations = selected;
        
        // Disable message buttons until conversation loads.
        enable_message_buttons(false);
        
        if (selected.size == 1 && current_folder != null) {
            Geary.Conversation conversation = Geary.Collection.get_first(selected);
            do_show_message.begin(conversation.get_emails(Geary.Conversation.Ordering.DATE_ASCENDING),
                cancellable_message, true, on_show_message_completed);
        } else if (current_folder != null) {
            main_window.conversation_viewer.show_multiple_selected(selected.size);
            if (selected.size > 1) {
                enable_multiple_message_buttons();
            } else {
                enable_message_buttons(false);
            }
        }
    }
    
    private async void do_show_message(Gee.Collection<Geary.Email> messages, Cancellable? 
        cancellable = null, bool clear_view = true) throws Error {
        set_busy(true);
        
        // Clear view before we yield, to make sure it happens
        if (clear_view) {
            main_window.conversation_viewer.clear(current_folder, account.settings);
            main_window.conversation_viewer.scroll_reset();
            main_window.conversation_viewer.external_images_info_bar.hide();
        }
        
        // Fetch full messages.
        Gee.List<Geary.EmailIdentifier> unread_ids = new Gee.ArrayList<Geary.EmailIdentifier>();
        Gee.Collection<Geary.Email> messages_to_add = new Gee.HashSet<Geary.Email>();
        foreach (Geary.Email email in messages) {
            Geary.Email full_email = yield current_folder.fetch_email_async(email.id,
                ConversationViewer.REQUIRED_FIELDS | Geary.ComposedEmail.REQUIRED_REPLY_FIELDS,
                Geary.Folder.ListFlags.NONE, cancellable);
            
            if (cancellable.is_cancelled())
                throw new IOError.CANCELLED("do_select_message cancelled");
            
            messages_to_add.add(full_email);
            
            if (full_email.email_flags.is_unread())
                unread_ids.add(full_email.id);
        }
        
        // Add messages.  conversation_viewer.add_message only adds new messages
        foreach (Geary.Email email in messages_to_add)
            main_window.conversation_viewer.add_message(email);
        
        main_window.conversation_viewer.unhide_last_email();
        
        // Mark as read.
        yield mark_as_read_async(unread_ids, cancellable);
    }
    
    private async void mark_as_read_async(Gee.List<Geary.EmailIdentifier> unread_ids,
        Cancellable? cancellable = null) throws Error {
        Geary.FolderSupportsMark? supports_mark = current_folder as Geary.FolderSupportsMark;
        if (supports_mark != null && unread_ids.size > 0) {
            Geary.EmailFlags flags = new Geary.EmailFlags();
            flags.add(Geary.EmailFlags.UNREAD);
            
            yield supports_mark.mark_email_async(unread_ids, null, flags, cancellable);
        }
    }
    
    private void on_show_message_completed(Object? source, AsyncResult result) {
        try {
            do_show_message.end(result);
            enable_message_buttons(true);
        } catch (Error err) {
            if (!(err is IOError.CANCELLED))
                debug("Unable to show message: %s", err.message);
        }
        
        set_busy(false);
    }
    
    private void on_special_folder_type_changed(Geary.Folder folder, Geary.SpecialFolderType old_type,
        Geary.SpecialFolderType new_type) {
        main_window.folder_list.remove_folder(folder);
        main_window.folder_list.add_folder(folder);
    }
    
    private void on_folders_added_removed(Gee.Collection<Geary.Folder>? added,
        Gee.Collection<Geary.Folder>? removed) {
        
        if (added != null && added.size > 0) {
            foreach (Geary.Folder folder in added) {
                main_window.folder_list.add_folder(folder);
                main_window.main_toolbar.copy_folder_menu.add_folder(folder);
                main_window.main_toolbar.move_folder_menu.add_folder(folder);
                
                // monitor the Inbox for notifications
                if (folder.get_special_folder_type() == Geary.SpecialFolderType.INBOX && inbox_folder == null) {
                    inbox_folder = folder;
                    
                    // select the inbox and get the show started
                    main_window.folder_list.select_path(folder.get_path());
                    inbox_folder.open_async.begin(false, cancellable_inbox);
                    
                    new_messages_monitor = new NewMessagesMonitor(inbox_folder, cancellable_inbox);
                    
                    // Unity launcher count (Ubuntuism)
                    unity_launcher = new UnityLauncher(new_messages_monitor);
                    
                    // libnotify
                    notification_bubble = new NotificationBubble(new_messages_monitor);
                    notification_bubble.invoked.connect(on_notification_bubble_invoked);
                    
                    // New messages indicator (Ubuntuism)
                    new_messages_indicator = NewMessagesIndicator.create(new_messages_monitor);
                    new_messages_indicator.application_activated.connect(on_indicator_activated_application);
                    new_messages_indicator.composer_activated.connect(on_indicator_activated_composer);
                    new_messages_indicator.inbox_activated.connect(on_indicator_activated_inbox);
                }
                
                folder.special_folder_type_changed.connect(on_special_folder_type_changed);
            }
            
            search_folders_for_children.begin(added);
        }
    }
    
    private async void search_folders_for_children(Gee.Collection<Geary.Folder> folders) {
        set_busy(true);
        Geary.NonblockingBatch batch = new Geary.NonblockingBatch();
        foreach (Geary.Folder folder in folders) {
            // Search for children unless Folder is absolutely certain it doesn't have any
            if (folder.has_children().is_possible())
                batch.add(new ListFoldersOperation(account, folder.get_path()));
        }
        
        debug("Listing %d folder children", batch.size);
        try {
            yield batch.execute_all_async();
        } catch (Error err) {
            debug("Unable to execute batch: %s", err.message);
            set_busy(false);
            
            return;
        }
        debug("Completed listing folder children");
        
        Gee.ArrayList<Geary.Folder> accumulator = new Gee.ArrayList<Geary.Folder>();
        foreach (int id in batch.get_ids()) {
            ListFoldersOperation op = (ListFoldersOperation) batch.get_operation(id);
            try {
                Gee.Collection<Geary.Folder> children = (Gee.Collection<Geary.Folder>) 
                    batch.get_result(id);
                accumulator.add_all(children);
            } catch (Error err2) {
                debug("Unable to list children of %s: %s", op.path.to_string(), err2.message);
            }
        }
        
        if (accumulator.size > 0)
            on_folders_added_removed(accumulator, null);
        
        set_busy(false);
    }
    
    private void cancel_folder() {
        Cancellable old_cancellable = cancellable_folder;
        cancellable_folder = new Cancellable();
        cancel_message();
        
        old_cancellable.cancel();
    }
     private void cancel_inbox() {
        Cancellable old_cancellable = cancellable_inbox;
        cancellable_inbox = new Cancellable();

        old_cancellable.cancel();
    }
    
    private void cancel_message() {
        Cancellable old_cancellable = cancellable_message;
        cancellable_message = new Cancellable();
        
        set_busy(false);
        
        old_cancellable.cancel();
    }
    
    // We need to include the second parameter, or valac doesn't recognize the function as matching
    // YorbaApplication.exiting's signature.
    private bool on_application_exiting(YorbaApplication sender, bool panicked) {
        if (close_composition_windows())
            return true;
        
        return sender.cancel_exit();
    }
    
    private void on_quit() {
        GearyApplication.instance.exit();
    }

    private void on_help() {
        try {
            if (GearyApplication.instance.is_installed()) {
                Gtk.show_uri(null, "ghelp:geary", Gdk.CURRENT_TIME);
            } else {
                Pid pid;
                File exec_dir = GearyApplication.instance.get_exec_dir();
                string[] argv = new string[3];
                argv[0] = "gnome-help";
                argv[1] = GearyApplication.SOURCE_ROOT_DIR + "/help/C/";
                argv[2] = null;
                if (!Process.spawn_async(exec_dir.get_path(), argv, null,
                    SpawnFlags.SEARCH_PATH | SpawnFlags.STDERR_TO_DEV_NULL, null, out pid)) {
                    debug("Failed to launch help locally.");
                }
            }
        } catch (Error error) {
            debug("Error showing help: %s", error.message);
            Gtk.Dialog dialog = new Gtk.Dialog.with_buttons("Error", null,
                Gtk.DialogFlags.DESTROY_WITH_PARENT, Gtk.Stock.CLOSE, Gtk.ResponseType.CLOSE, null);
            dialog.response.connect(() => { dialog.destroy(); });
            dialog.get_content_area().add(new Gtk.Label("Error showing help: %s".printf(error.message)));
            dialog.show_all();
            dialog.run();
        }
    }

    private void on_about() {
        Gtk.show_about_dialog(main_window,
            "program-name", GearyApplication.NAME,
            "comments", GearyApplication.DESCRIPTION,
            "authors", GearyApplication.AUTHORS,
            "copyright", GearyApplication.COPYRIGHT,
            "license", GearyApplication.LICENSE,
            "version", GearyApplication.VERSION,
            "website", GearyApplication.WEBSITE,
            "website-label", GearyApplication.WEBSITE_LABEL,
            "title", _("About %s").printf(GearyApplication.NAME),
            /// Translator credit for the About dialog
            "translator-credits", _("translator-credits")
        );
    }
    
    private void on_preferences() {
        PreferencesDialog dialog = new PreferencesDialog(GearyApplication.instance.config);
        dialog.run();
    }

    private Gee.List<Geary.EmailIdentifier> get_selected_ids(bool only_get_preview_message = false) {
        Gee.List<Geary.EmailIdentifier> ids = new Gee.ArrayList<Geary.EmailIdentifier>();
        foreach (Geary.Conversation conversation in selected_conversations) {
            if (only_get_preview_message) {
                Geary.Email? preview_message = conversation.get_latest_email();
                if (preview_message != null) {
                    ids.add(preview_message.id);
                }
            } else {
                ids.add_all(conversation.get_email_ids());
            }
        }
        return ids;
    }

    private void mark_selected_conversations(Geary.EmailFlags? flags_to_add,
        Geary.EmailFlags? flags_to_remove, bool only_get_preview_message = false) {
        Geary.FolderSupportsMark? supports_mark = current_folder as Geary.FolderSupportsMark;
        if (supports_mark == null)
            return;
        
        // Mark the emails.
        Gee.List<Geary.EmailIdentifier> ids = get_selected_ids(only_get_preview_message);
        if (ids.size > 0) {
            set_busy(true);
            supports_mark.mark_email_async.begin(ids, flags_to_add, flags_to_remove,
                cancellable_message, on_mark_complete);
        }
    }

    private void on_show_mark_menu() {
        bool unread_selected = false;
        bool read_selected = false;
        bool starred_selected = false;
        bool unstarred_selected = false;
        foreach (Geary.Conversation conversation in selected_conversations) {
            if (conversation.is_unread())
                unread_selected = true;
            if (conversation.has_any_read_message())
                read_selected = true;

            if (conversation.is_flagged()) {
                starred_selected = true;
            } else {
                unstarred_selected = true;
            }
        }
        var actions = GearyApplication.instance.actions;
        actions.get_action(ACTION_MARK_AS_READ).set_visible(unread_selected);
        actions.get_action(ACTION_MARK_AS_UNREAD).set_visible(read_selected);
        actions.get_action(ACTION_MARK_AS_STARRED).set_visible(unstarred_selected);
        actions.get_action(ACTION_MARK_AS_UNSTARRED).set_visible(starred_selected);
    }

    private void on_mark_conversation(Geary.Conversation conversation,
        Geary.EmailFlags? flags_to_add, Geary.EmailFlags? flags_to_remove, bool only_mark_preview = false) {
        Geary.FolderSupportsMark? supports_mark = current_folder as Geary.FolderSupportsMark;
        if (supports_mark == null)
            return;
        
        Gee.List<Geary.EmailIdentifier> ids = new Gee.ArrayList<Geary.EmailIdentifier>();
        if (only_mark_preview) {
            Geary.Email? email = conversation.get_latest_email();
            if (email != null) {
                ids.add(email.id);
            }
        } else {
            ids.add_all(conversation.get_email_ids());
        }
        
        if (ids.size > 0) {
            set_busy(true);
            supports_mark.mark_email_async.begin(ids, flags_to_add, flags_to_remove,
                cancellable_message, on_mark_complete);
        }
    }

    private void on_conversation_viewer_mark_message(Geary.Email message, Geary.EmailFlags? flags_to_add,
        Geary.EmailFlags? flags_to_remove) {
        Geary.FolderSupportsMark? supports_mark = current_folder as Geary.FolderSupportsMark;
        if (supports_mark == null)
            return;
        
        set_busy(true);
        supports_mark.mark_single_email_async.begin(message.id, flags_to_add, flags_to_remove,
            cancellable_message, on_mark_complete);
    }
    
    private void on_mark_as_read() {
        Geary.EmailFlags flags = new Geary.EmailFlags();
        flags.add(Geary.EmailFlags.UNREAD);
        mark_selected_conversations(null, flags);
    }

    private void on_mark_as_unread() {
        Geary.EmailFlags flags = new Geary.EmailFlags();
        flags.add(Geary.EmailFlags.UNREAD);
        mark_selected_conversations(flags, null);
    }

    private void on_mark_as_starred() {
        Geary.EmailFlags flags = new Geary.EmailFlags();
        flags.add(Geary.EmailFlags.FLAGGED);
        mark_selected_conversations(flags, null, true);
    }

    private void on_mark_as_unstarred() {
        Geary.EmailFlags flags = new Geary.EmailFlags();
        flags.add(Geary.EmailFlags.FLAGGED);
        mark_selected_conversations(null, flags);
    }
    
    private void on_mark_complete() {
        set_busy(false);
    }

    private void on_show_copy_menu() {
        main_window.main_toolbar.copy_folder_menu.show();
    }

    private void on_show_move_menu() {
        main_window.main_toolbar.move_folder_menu.show();
    }

    private void on_copy_conversation(Geary.Folder destination) {
        // Nothing to do if nothing selected.
        if (selected_conversations == null || selected_conversations.size == 0)
            return;
        
        Gee.List<Geary.EmailIdentifier> ids = get_selected_ids();
        if (ids.size == 0)
            return;
        
        Geary.FolderSupportsCopy? supports_copy = current_folder as Geary.FolderSupportsCopy;
        if (supports_copy == null)
            return;
        
        set_busy(true);
        supports_copy.copy_email_async.begin(ids, destination.get_path(), cancellable_message,
            on_copy_complete);
    }

    private void on_copy_complete() {
        set_busy(false);
    }

    private void on_move_conversation(Geary.Folder destination) {
        // Nothing to do if nothing selected.
        if (selected_conversations == null || selected_conversations.size == 0)
            return;
        
        Gee.List<Geary.EmailIdentifier> ids = get_selected_ids();
        if (ids.size == 0)
            return;
        
        Geary.FolderSupportsMove? supports_move = current_folder as Geary.FolderSupportsMove;
        if (supports_move == null)
            return;
        
        set_busy(true);
        supports_move.move_email_async.begin(ids, destination.get_path(), cancellable_message,
            on_move_complete);
    }

    private void on_move_complete() {
        set_busy(false);
    }

    private void on_open_attachment(Geary.Attachment attachment) {
        if (GearyApplication.instance.config.ask_open_attachment) {
            QuestionDialog ask_to_open = new QuestionDialog.with_checkbox(main_window,
                _("Are you sure you want to open \"%s\"?").printf(attachment.filename),
                _("Attachments may cause damage to your system if opened.  Only open files from trusted sources."),
                Gtk.Stock.OPEN, Gtk.Stock.CANCEL, _("Don't _ask me again"), false);
            if (ask_to_open.run() != Gtk.ResponseType.OK)
                return;
            
            // only save checkbox state if OK was selected
            GearyApplication.instance.config.ask_open_attachment = !ask_to_open.is_checked;
        }
        
        open_uri("file://" + attachment.filepath);
    }
    
    private bool do_overwrite_confirmation(File to_overwrite) {
        string primary = _("A file named \"%s\" already exists.  Do you want to replace it?").printf(
            to_overwrite.get_basename());
        string secondary = _("The file already exists in \"%s\".  Replacing it will overwrite its contents.").printf(
            to_overwrite.get_parent().get_basename());
        
        ConfirmationDialog dialog = new ConfirmationDialog(main_window, primary, secondary, _("_Replace"));
        
        return (dialog.run() == Gtk.ResponseType.OK);
    }
    
    private Gtk.FileChooserConfirmation on_confirm_overwrite(Gtk.FileChooser chooser) {
        // this is only called when choosing one file
        return do_overwrite_confirmation(chooser.get_file()) ? Gtk.FileChooserConfirmation.ACCEPT_FILENAME
            : Gtk.FileChooserConfirmation.SELECT_AGAIN;
    }
    
    private void on_save_attachments(Gee.List<Geary.Attachment> attachments) {
        if (attachments.size == 0)
            return;
        
        Gtk.FileChooserAction action = (attachments.size == 1)
            ? Gtk.FileChooserAction.SAVE
            : Gtk.FileChooserAction.SELECT_FOLDER;
        Gtk.FileChooserDialog dialog = new Gtk.FileChooserDialog(null, main_window, action,
            Gtk.Stock.CANCEL, Gtk.ResponseType.CANCEL, Gtk.Stock.SAVE, Gtk.ResponseType.ACCEPT, null);
        if (last_save_directory != null)
            dialog.set_current_folder(last_save_directory.get_path());
        if (attachments.size == 1) {
            dialog.set_current_name(attachments[0].filename);
            dialog.set_do_overwrite_confirmation(true);
            // use custom overwrite confirmation so it looks consistent whether one or many
            // attachments are being saved
            dialog.confirm_overwrite.connect(on_confirm_overwrite);
        }
        dialog.set_create_folders(true);
        
        bool accepted = (dialog.run() == Gtk.ResponseType.ACCEPT);
        File destination = File.new_for_path(dialog.get_filename());
        
        dialog.destroy();
        
        if (!accepted)
            return;
        
        // Proceeding, save this as last destination directory
        last_save_directory = (attachments.size == 1) ? destination.get_parent() : destination;
        
        debug("Saving attachments to %s", destination.get_path());
        
        // Save each one, checking for overwrite only if multiple attachments are being written
        foreach (Geary.Attachment attachment in attachments) {
            File source_file = File.new_for_path(attachment.filepath);
            File dest_file = (attachments.size == 1) ? destination : destination.get_child(attachment.filename);
            
            if (attachments.size > 1 && dest_file.query_exists() && !do_overwrite_confirmation(dest_file))
                return;
            
            debug("Copying %s to %s...", source_file.get_path(), dest_file.get_path());
            
            source_file.copy_async.begin(dest_file, FileCopyFlags.OVERWRITE, Priority.DEFAULT, null,
                null, on_save_completed);
        }
    }
    
    private void on_save_completed(Object? source, AsyncResult result) {
        try {
            ((File) source).copy_async.end(result);
        } catch (Error error) {
            warning("Failed to copy attachment %s to destination: %s", ((File) source).get_path(),
                error.message);
        }
    }

    // Opens a link in an external browser.
    private void open_uri(string _link) {
        string link = _link;
        
        // Support web URLs that ommit the protocol.
        if (!link.contains(":"))
            link = "http://" + link;
        
        try {
            Gtk.show_uri(main_window.get_screen(), link, Gdk.CURRENT_TIME);
        } catch (Error err) {
            debug("Unable to open URL. %s", err.message);
        }
    }
    
    private bool close_composition_windows() {
        // We want to allow the user to cancel a quit when they have unsent text.
        
        // We are modifying the list as we go, so we can't simply iterate through it.
        while (composer_windows.size > 0) {
            ComposerWindow composer_window = composer_windows.first();
            if (!composer_window.should_close())
                return false;
            
            // This will remove composer_window from composer_windows.
            // See GearyController.on_composer_window_destroy.
            composer_window.destroy();
        }
        
        // If we deleted all composer windows without the user cancelling, we can exit.
        return true;
    }
    
    private void create_compose_window(Geary.ComposedEmail? prefill = null) {
        Geary.ContactStore? contact_store = account == null ? null : account.get_contact_store();
        ComposerWindow window = new ComposerWindow(contact_store, prefill);
        window.set_position(Gtk.WindowPosition.CENTER);
        window.send.connect(on_send);
        
        // We want to keep track of the open composer windows, so we can allow the user to cancel
        // an exit without losing their data.
        composer_windows.add(window);
        window.destroy.connect(on_composer_window_destroy);
        
        window.show_all();
    }
    
    private void on_composer_window_destroy(Gtk.Widget sender) {
        composer_windows.remove((ComposerWindow) sender);
    }
    
    private void on_new_message() {
        create_compose_window();
    }
    
    private void on_reply_to_message(Geary.Email message) {
        create_compose_window(new Geary.ComposedEmail.as_reply(new DateTime.now_local(),
            get_from(), message));
    }
    
    private void on_reply_to_message_action() {
        Geary.Email? message = main_window.conversation_viewer.get_last_message();
        if (message != null)
            on_reply_to_message(message);
    }
    
    private void on_reply_all_message(Geary.Email message) {
        create_compose_window(new Geary.ComposedEmail.as_reply_all(new DateTime.now_local(),
            get_from(), message));
    }
    
    private void on_reply_all_message_action() {
        Geary.Email? message = main_window.conversation_viewer.get_last_message();
        if (message != null)
            on_reply_all_message(message);
    }
    
    private void on_forward_message(Geary.Email message) {
        create_compose_window(new Geary.ComposedEmail.as_forward(new DateTime.now_local(),
            get_from(), message));
    }
    
    private void on_forward_message_action() {
        Geary.Email? message = main_window.conversation_viewer.get_last_message();
        if (message != null)
            on_forward_message(message);
    }
    
    // This method is used for both removing and archive a message; currently Geary only supports
    // one or the other in a folder
    private void on_delete_message() {
        // Prevent deletes of the same conversation from repeating.
        if (is_viewed_conversation(last_deleted_conversation))
            return;
        
        // There should always be at least one conversation selected here, otherwise the archive
        // button is disabled, but better safe than segfaulted.
        last_deleted_conversation = selected_conversations.size > 0
            ? Geary.Collection.get_first<Geary.Conversation>(selected_conversations) : null;

        // If the user clicked the toolbar button, we want to move focus back to the message list.
        main_window.conversation_list_view.grab_focus();
        set_busy(true);

        // Collect all the emails into one pool and then delete.
        Gee.Set<Geary.Email> all_emails = new Gee.TreeSet<Geary.Email>();
        foreach (Geary.Conversation conversation in selected_conversations)
            all_emails.add_all(conversation.get_emails(Geary.Conversation.Ordering.NONE));
        
        delete_messages.begin(all_emails, cancellable_folder, on_delete_messages_completed);
    }
    
    // This method is used for both removing and archive a message; currently Geary only supports
    // one or the other in a folder.  This will try archiving first, then remove.
    private async void delete_messages(Gee.Collection<Geary.Email> messages, Cancellable? cancellable)
        throws Error {
        Gee.List<Geary.EmailIdentifier> list = new Gee.ArrayList<Geary.EmailIdentifier>();
        foreach (Geary.Email email in messages)
            list.add(email.id);
        
        Geary.FolderSupportsArchive? supports_archive = current_folder as Geary.FolderSupportsArchive;
        if (supports_archive != null) {
            yield supports_archive.archive_email_async(list, cancellable);
            
            return;
        }
        
        Geary.FolderSupportsRemove? supports_remove = current_folder as Geary.FolderSupportsRemove;
        if (supports_remove != null) {
            yield supports_remove.remove_email_async(list, cancellable);
            
            return;
        }
        
        debug("Folder %s supports neither remove nor archive", current_folder.to_string());
    }

    private void on_delete_messages_completed(Object? source, AsyncResult result) {
        try {
            delete_messages.end(result);
        } catch (Error err) {
            debug("Error, unable to delete messages: %s", err.message);
        }
        
        set_busy(false);
    }
    
    private void on_zoom_in() {
        main_window.conversation_viewer.web_view.zoom_in();
    }

    private void on_zoom_out() {
        main_window.conversation_viewer.web_view.zoom_out();
    }

    private void on_zoom_normal() {
        main_window.conversation_viewer.web_view.zoom_level = 1.0f;
    }
    
    private Geary.RFC822.MailboxAddress get_sender() {
        return account.settings.email;
    }
    
    private Geary.RFC822.MailboxAddresses get_from() {
        return new Geary.RFC822.MailboxAddresses.single(get_sender());
    }
        
    private void on_send(ComposerWindow composer_window) {
        account.send_email_async.begin(composer_window.get_composed_email(get_from()));
        composer_window.destroy();
    }

    private void on_sent(Geary.RFC822.Message rfc822) {
        NotificationBubble.play_sound("message-sent-email");
    }
    
    public void set_busy(bool is_busy) {
        busy_count += is_busy ? 1 : -1;
        if (busy_count < 0)
            busy_count = 0;
        
        main_window.set_busy(busy_count > 0);
    }

    private void on_link_selected(string link) {
        if (link.down().has_prefix(Geary.ComposedEmail.MAILTO_SCHEME)) {
            compose_mailto(link);
        } else {
            open_uri(link);
        }
    }

    // Disables all single-message buttons and enables all multi-message buttons.
    public void enable_multiple_message_buttons(){
        // Single message only buttons.
        GearyApplication.instance.actions.get_action(ACTION_REPLY_TO_MESSAGE).sensitive = false;
        GearyApplication.instance.actions.get_action(ACTION_REPLY_ALL_MESSAGE).sensitive = false;
        GearyApplication.instance.actions.get_action(ACTION_FORWARD_MESSAGE).sensitive = false;

        // Mutliple message buttons.
        GearyApplication.instance.actions.get_action(ACTION_DELETE_MESSAGE).sensitive =
            (current_folder is Geary.FolderSupportsRemove) || (current_folder is Geary.FolderSupportsArchive);
        GearyApplication.instance.actions.get_action(ACTION_MARK_AS_MENU).sensitive =
            current_folder is Geary.FolderSupportsMark;
        GearyApplication.instance.actions.get_action(ACTION_COPY_MENU).sensitive =
            current_folder is Geary.FolderSupportsCopy;
        GearyApplication.instance.actions.get_action(ACTION_MOVE_MENU).sensitive =
            current_folder is Geary.FolderSupportsMove;
    }

    // Enables or disables the message buttons on the toolbar.
    public void enable_message_buttons(bool sensitive) {
        GearyApplication.instance.actions.get_action(ACTION_REPLY_TO_MESSAGE).sensitive = sensitive;
        GearyApplication.instance.actions.get_action(ACTION_REPLY_ALL_MESSAGE).sensitive = sensitive;
        GearyApplication.instance.actions.get_action(ACTION_FORWARD_MESSAGE).sensitive = sensitive;
        GearyApplication.instance.actions.get_action(ACTION_DELETE_MESSAGE).sensitive = sensitive
            && ((current_folder is Geary.FolderSupportsRemove) || (current_folder is Geary.FolderSupportsArchive));
        GearyApplication.instance.actions.get_action(ACTION_MARK_AS_MENU).sensitive =
            sensitive && (current_folder is Geary.FolderSupportsMark);
        GearyApplication.instance.actions.get_action(ACTION_COPY_MENU).sensitive =
            sensitive && (current_folder is Geary.FolderSupportsCopy);
        GearyApplication.instance.actions.get_action(ACTION_MOVE_MENU).sensitive =
            sensitive && (current_folder is Geary.FolderSupportsMove);
    }

    public void compose_mailto(string mailto) {
        create_compose_window(new Geary.ComposedEmail.from_mailto(mailto, get_from()));
    }
}

