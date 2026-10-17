import os
import re
from datetime import datetime, timezone
from pathlib import Path

import flet as ft
from dotenv import load_dotenv
from supabase import Client, create_client

# ── Customize these two lines for your church ──────────────────────
CHURCH_NAME = "UTCCNJ"          # ← change to your church's name
SEED_COLOR = ft.Colors.DEEP_PURPLE                   # ← try TEAL, DEEP_PURPLE, BROWN, GREEN, etc.
# ────────────────────────────────────────────────────────────────────

load_dotenv(Path(__file__).parent / ".env")
supabase: Client = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_ANON_KEY"])

CATEGORY_ICONS = {
    "announcements": ft.Icons.CAMPAIGN,
    "events": ft.Icons.EVENT,
}

# Categories the app can insert/edit/delete, gated by role_features. Maps
# category -> (feature key, singular label for buttons/dialogs).
EDITABLE_CATEGORIES = {
    "announcements": ("edit_announcements", "announcement"),
    "events": ("edit_events", "event"),
}

# category -> its table's primary key column name
CATEGORY_ID_COLUMN = {
    "announcements": "announcement_id",
    "events": "event_id",
}


def format_date(iso_str):
    dt = datetime.fromisoformat(iso_str)
    return f"{dt.strftime('%B')} {dt.day}"


def display_date(item, category):
    return item["date_label"] if category == "events" else format_date(item["created_at"])


def fetch_announcements():
    return supabase.table("announcements").select("*").order("created_at", desc=True).execute().data


def fetch_events():
    return supabase.table("events").select("*").order("created_at", desc=True).execute().data


def fetch_song_titles():
    return supabase.table("songs_titles").select("*").order("title_english").execute().data


def song_title(song, language_preference):
    if language_preference == "telugu" and song.get("title_telugu"):
        return song["title_telugu"]
    return song["title_english"] or song["title_telugu"]


def song_display(song, language_preference):
    label = f"{song['song_title_id']}. {song_title(song, language_preference)}"
    if song.get("musical_key"):
        label += f" ({song['musical_key']})"
    return label


def fetch_song_lyrics(song_id):
    return (
        supabase.table("songs_lyrics")
        .select("*")
        .eq("song_id", song_id)
        .order("verse_number")
        .order("verse_part_number")
        .execute()
        .data
    )


def lyric_line_text(line, language_preference):
    if language_preference == "telugu" and line.get("telugu_text"):
        text = line["telugu_text"]
    else:
        text = line["english_text"] or line["telugu_text"]
    return (text or "").strip()


def fetch_assignments():
    return (
        supabase.table("assignments")
        .select("*")
        .eq("deleted", False)
        .order("created_time", desc=True)
        .execute()
        .data
    )


def fetch_my_assignments(member_id):
    return supabase.rpc("get_my_assignments", {"p_member_id": member_id}).execute().data


def mark_assignment_response_complete(response_id, member_id):
    supabase.rpc(
        "mark_assignment_response_complete",
        {"p_response_id": response_id, "p_member_id": member_id},
    ).execute()


def insert_assignment(title, description, class_id, teacher_id, category):
    created_time = datetime.now(timezone.utc).replace(tzinfo=None).isoformat()
    result = supabase.table("assignments").insert(
        {
            "assignment_title": title,
            "assignment_description": description,
            "class_id": class_id,
            "teacher_id": teacher_id,
            "created_time": created_time,
            "Category": category,
            "closed": False,
            "deleted": False,
        }
    ).execute()
    assignment_id = result.data[0]["assignment_id"]
    create_assignment_responses(assignment_id, class_id, created_time)


def create_assignment_responses(assignment_id, class_id, created_time):
    students = supabase.rpc("get_students_for_class", {"p_class_id": class_id}).execute().data
    if not students:
        return
    rows = [
        {
            "assignment_id": assignment_id,
            "student_id": s["student_id"],
            "father_id": s["father_id"],
            "mother_id": s["mother_id"],
            "family_code": s["family_code"],
            "assignment_post_createdtime": created_time,
        }
        for s in students
    ]
    supabase.table("assignment_post_response").insert(rows, returning="minimal").execute()


def fetch_class_for_teacher(teacher_id):
    rows = supabase.table("classes").select("*").eq("teacher_id", teacher_id).execute().data
    return rows[0] if rows else None


def fetch_classes():
    return supabase.table("classes").select("*").order("name").execute().data


def fetch_by_id(table, id_column, item_id):
    rows = supabase.table(table).select("*").eq(id_column, item_id).execute().data
    return rows[0] if rows else None


def member_login_lookup(phone_number):
    rows = supabase.rpc("member_login_lookup", {"p_phone_number": phone_number}).execute().data
    return rows[0] if rows else None


def has_feature(role, feature):
    if not role:
        return False
    rows = (
        supabase.table("role_features")
        .select("feature")
        .eq("role", role)
        .eq("feature", feature)
        .execute()
        .data
    )
    return bool(rows)


def insert_announcement(title, body):
    supabase.table("announcements").insert({"title": title, "body": body}).execute()


def update_announcement(item_id, title, body):
    supabase.table("announcements").update({"title": title, "body": body}).eq("announcement_id", item_id).execute()


def insert_event(title, body, date_label):
    supabase.table("events").insert({"title": title, "body": body, "date_label": date_label}).execute()


def update_event(item_id, title, body, date_label):
    supabase.table("events").update(
        {"title": title, "body": body, "date_label": date_label}
    ).eq("event_id", item_id).execute()


def delete_item(table, id_column, item_id):
    supabase.table(table).delete().eq(id_column, item_id).execute()


def main(page: ft.Page):
    page.title = CHURCH_NAME
    page.theme = ft.Theme(color_scheme_seed=SEED_COLOR)
    page.padding = 0

    user = {
        "id": None,
        "first_name": None,
        "role": None,
        "phone": None,
        "language_preference": None,
        "signed_in": False,
        "is_guest": False,
    }

    def is_logged_in():
        return user["signed_in"]

    def do_login_guest():
        user.update(
            {
                "id": None,
                "first_name": None,
                "role": None,
                "phone": None,
                "language_preference": None,
                "signed_in": True,
                "is_guest": True,
            }
        )

    def do_login(phone_number):
        result = member_login_lookup(phone_number)
        if result:
            user.update(
                {
                    "id": result["id"],
                    "first_name": result["first_name"],
                    "role": result["role_in_church"],
                    "phone": re.sub(r"\D", "", phone_number),
                    "language_preference": result["language_preference"],
                    "signed_in": True,
                    "is_guest": False,
                }
            )
            return True
        return False

    def do_logout():
        user.update(
            {
                "id": None,
                "first_name": None,
                "role": None,
                "phone": None,
                "language_preference": None,
                "signed_in": False,
                "is_guest": False,
            }
        )

    def go_to(route):
        async def handler(e):
            await page.push_route(route)

        return handler

    def open_item(category, item_id):
        async def handler(e):
            await page.push_route(f"/{category}/{item_id}")

        return handler

    def logout_click(e):
        do_logout()
        route_change(page.route)

    def build_login_view():
        phone_field = ft.TextField(label="Phone number (optional)", autofocus=True)
        error_text = ft.Text("", color=ft.Colors.RED)

        async def submit(e):
            value = (phone_field.value or "").strip()
            print(f"[login] submit fired, value={value!r}", flush=True)
            if not value:
                do_login_guest()
                route_change(page.route)
                return
            try:
                found = do_login(value)
            except Exception as ex:
                print(f"[login] error: {ex!r}", flush=True)
                error_text.value = f"Error reaching the server: {ex}"
                page.update()
                return
            if found:
                route_change(page.route)
            else:
                error_text.value = "Not found. Check with the church office to be added."
                page.update()

        return ft.View(
            route="/login",
            controls=[
                ft.Container(
                    content=ft.Column(
                        [
                            ft.Icon(ft.Icons.CHURCH, size=64, color=ft.Colors.PRIMARY),
                            ft.Text(CHURCH_NAME, size=26, weight=ft.FontWeight.BOLD),
                            ft.Text("Sign in with your phone number, or continue as a guest", color=ft.Colors.GREY),
                            phone_field,
                            ft.FilledButton("Continue", on_click=submit),
                            error_text,
                        ],
                        horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                        spacing=14,
                    ),
                    padding=ft.Padding.symmetric(horizontal=24, vertical=60),
                )
            ],
        )

    def build_list_view(route, title, items, category):
        icon = CATEGORY_ICONS.get(category, ft.Icons.ARTICLE)
        id_column = CATEGORY_ID_COLUMN[category]
        actions = []
        editable = EDITABLE_CATEGORIES.get(category)
        if editable and has_feature(user["role"], editable[0]):
            actions.append(
                ft.IconButton(ft.Icons.ADD, tooltip=f"New {editable[1]}", on_click=go_to(f"/{category}/new"))
            )
        return ft.View(
            route=route,
            appbar=ft.AppBar(title=ft.Text(title), actions=actions),
            controls=[
                ft.ListTile(
                    leading=ft.Icon(icon),
                    title=ft.Text(item["title"]),
                    subtitle=ft.Text(display_date(item, category)),
                    trailing=ft.Icon(ft.Icons.CHEVRON_RIGHT),
                    on_click=open_item(category, item[id_column]),
                )
                for item in items
            ],
        )

    def delete_item_click(table, id_column, item_id, redirect_route, label):
        async def handler(e):
            async def do_delete(e2):
                page.pop_dialog()
                delete_item(table, id_column, item_id)
                await page.push_route(redirect_route)

            def cancel(e2):
                page.pop_dialog()

            page.show_dialog(
                ft.AlertDialog(
                    modal=True,
                    title=ft.Text(f"Delete this {label}?"),
                    content=ft.Text("This can't be undone."),
                    actions=[
                        ft.TextButton("Cancel", on_click=cancel),
                        ft.TextButton("Delete", on_click=do_delete),
                    ],
                )
            )

        return handler

    def build_detail_view(route, item, category):
        id_column = CATEGORY_ID_COLUMN[category]
        item_id = item[id_column]
        actions = []
        editable = EDITABLE_CATEGORIES.get(category)
        if editable and has_feature(user["role"], editable[0]):
            label = editable[1]
            actions.append(
                ft.IconButton(ft.Icons.EDIT, tooltip="Edit", on_click=go_to(f"/{category}/{item_id}/edit"))
            )
            actions.append(
                ft.IconButton(
                    ft.Icons.DELETE,
                    tooltip="Delete",
                    on_click=delete_item_click(category, id_column, item_id, f"/{category}", label),
                )
            )
        return ft.View(
            route=route,
            appbar=ft.AppBar(title=ft.Text(item["title"]), actions=actions),
            controls=[
                ft.Text(display_date(item, category), size=14, color=ft.Colors.GREY),
                ft.Divider(),
                ft.Text(item["body"], size=16),
            ],
        )

    def build_announcement_form_view(item=None):
        is_edit = item is not None
        title_field = ft.TextField(label="Title", value=item["title"] if is_edit else "")
        body_field = ft.TextField(
            label="Body", multiline=True, min_lines=4, value=item["body"] if is_edit else ""
        )
        status_text = ft.Text("", color=ft.Colors.RED)

        async def submit(e):
            if not title_field.value or not body_field.value:
                status_text.value = "Please fill in both fields."
                page.update()
                return
            try:
                if is_edit:
                    update_announcement(item["announcement_id"], title_field.value.strip(), body_field.value.strip())
                else:
                    insert_announcement(title_field.value.strip(), body_field.value.strip())
            except Exception as ex:
                status_text.value = f"Error: {ex}"
                page.update()
                return
            await page.push_route(f"/announcements/{item['announcement_id']}" if is_edit else "/announcements")

        route = f"/announcements/{item['announcement_id']}/edit" if is_edit else "/announcements/new"
        return ft.View(
            route=route,
            appbar=ft.AppBar(title=ft.Text("Edit Announcement" if is_edit else "New Announcement")),
            controls=[
                ft.Container(
                    content=ft.Column(
                        [
                            title_field,
                            body_field,
                            ft.FilledButton("Save" if is_edit else "Post", on_click=submit),
                            status_text,
                        ],
                        spacing=14,
                    ),
                    padding=16,
                )
            ],
        )

    def build_event_form_view(item=None):
        is_edit = item is not None
        title_field = ft.TextField(label="Title", value=item["title"] if is_edit else "")
        date_label_field = ft.TextField(
            label="Date (free-form, e.g. \"July 14 - July 18\")", value=item["date_label"] if is_edit else ""
        )
        body_field = ft.TextField(
            label="Body", multiline=True, min_lines=4, value=item["body"] if is_edit else ""
        )
        status_text = ft.Text("", color=ft.Colors.RED)

        async def submit(e):
            if not title_field.value or not body_field.value or not date_label_field.value:
                status_text.value = "Please fill in all fields."
                page.update()
                return
            try:
                if is_edit:
                    update_event(
                        item["event_id"],
                        title_field.value.strip(),
                        body_field.value.strip(),
                        date_label_field.value.strip(),
                    )
                else:
                    insert_event(title_field.value.strip(), body_field.value.strip(), date_label_field.value.strip())
            except Exception as ex:
                status_text.value = f"Error: {ex}"
                page.update()
                return
            await page.push_route(f"/events/{item['event_id']}" if is_edit else "/events")

        route = f"/events/{item['event_id']}/edit" if is_edit else "/events/new"
        return ft.View(
            route=route,
            appbar=ft.AppBar(title=ft.Text("Edit Event" if is_edit else "New Event")),
            controls=[
                ft.Container(
                    content=ft.Column(
                        [
                            title_field,
                            date_label_field,
                            body_field,
                            ft.FilledButton("Save" if is_edit else "Post", on_click=submit),
                            status_text,
                        ],
                        spacing=14,
                    ),
                    padding=16,
                )
            ],
        )

    def build_songs_view():
        songs = fetch_song_titles()
        selected_ids = set()
        status_text = ft.Text("", color=ft.Colors.RED)
        categories = sorted({s["category"] for s in songs if s.get("category")})

        def toggle(song_id):
            def handler(e):
                if e.control.value:
                    selected_ids.add(song_id)
                else:
                    selected_ids.discard(song_id)

            return handler

        async def share_click(e):
            if not selected_ids:
                status_text.value = "Select at least one song first."
                status_text.color = ft.Colors.RED
                page.update()
                return

            titles = [
                song_display(s, user["language_preference"]) for s in songs if s["song_title_id"] in selected_ids
            ]
            message = "Songs for choir:\n" + "\n".join(f"- {t}" for t in titles)

            try:
                await page.clipboard.set(message)
                status_text.value = "Copied! Paste it into WhatsApp."
                status_text.color = ft.Colors.GREEN
            except Exception as ex:
                status_text.value = f"Error copying: {ex}"
                status_text.color = ft.Colors.RED
            page.update()

        checklist_column = ft.Column(spacing=4)

        def render_checklist(category_filter):
            visible = [s for s in songs if category_filter == "All" or s.get("category") == category_filter]
            checklist_column.controls = [
                ft.ListTile(
                    leading=ft.Checkbox(
                        value=s["song_title_id"] in selected_ids,
                        on_change=toggle(s["song_title_id"]),
                    ),
                    title=ft.Text(song_display(s, user["language_preference"])),
                    on_click=open_item("songs", s["song_title_id"]),
                )
                for s in visible
            ] or [ft.Text("No songs in this category.", color=ft.Colors.GREY)]

        def category_changed(e):
            render_checklist(category_dropdown.value)
            page.update()

        category_dropdown = ft.Dropdown(
            label="Category",
            value="All",
            options=[ft.DropdownOption(key="All", text="All")]
            + [ft.DropdownOption(key=c, text=c) for c in categories],
            on_select=category_changed,
        )
        render_checklist("All")

        return ft.View(
            route="/songs",
            appbar=ft.AppBar(title=ft.Text("Songs")),
            controls=[
                ft.Container(
                    content=ft.Column(
                        [
                            category_dropdown,
                            checklist_column,
                            ft.FilledButton("Copy for Whatsapp", on_click=share_click),
                            status_text,
                        ]
                        if songs
                        else [ft.Text("No songs added yet.", color=ft.Colors.GREY)],
                        spacing=10,
                    ),
                    padding=16,
                )
            ],
        )

    def build_song_lyrics_view(song_title_id):
        song = fetch_by_id("songs_titles", "song_title_id", song_title_id)
        if not song:
            return ft.View(
                route=f"/songs/{song_title_id}",
                appbar=ft.AppBar(title=ft.Text("Song")),
                controls=[ft.Text("This song was removed.", color=ft.Colors.GREY)],
            )

        lines = fetch_song_lyrics(song_title_id)

        controls = []
        last_section = None
        for line in lines:
            section = (line.get("verse_type"), line.get("verse_number"))
            if section != last_section:
                if last_section is not None:
                    controls.append(ft.Container(height=16))
                last_section = section
                section_label = f"{line.get('verse_type') or 'Verse'} {line.get('verse_number') or ''}".strip()
                controls.append(ft.Text(section_label, size=16, weight=ft.FontWeight.BOLD))
            text = lyric_line_text(line, user["language_preference"])
            if line.get("repetitions") and line["repetitions"] > 1:
                text += f" (x{line['repetitions']})"
            controls.append(ft.Text(text, size=16))

        return ft.View(
            route=f"/songs/{song_title_id}",
            appbar=ft.AppBar(title=ft.Text(song_display(song, user["language_preference"]))),
            controls=[
                ft.Container(
                    content=ft.Column(
                        controls or [ft.Text("No lyrics added yet.", color=ft.Colors.GREY)],
                        spacing=8,
                        scroll=ft.ScrollMode.AUTO,
                    ),
                    padding=16,
                    expand=True,
                )
            ],
        )

    def build_assignments_view():
        assignments = fetch_assignments()
        classes_by_id = {c["class_id"]: c["name"] for c in fetch_classes()}

        tiles = [
            ft.ListTile(
                leading=ft.Icon(ft.Icons.ASSIGNMENT),
                title=ft.Text(f"{a['assignment_title']} · {format_date(a['created_time'])}"),
                subtitle=ft.Text(
                    f"{classes_by_id.get(a['class_id'], 'Unknown class')} · {a.get('Category') or 'No category'}"
                ),
            )
            for a in assignments
        ]

        return ft.View(
            route="/assignments",
            appbar=ft.AppBar(title=ft.Text("Sunday School Teacher")),
            controls=[
                ft.Container(
                    content=ft.FilledButton("Create a new assignment", on_click=go_to("/assignments/new")),
                    padding=16,
                ),
                *(tiles if tiles else [ft.Text("No assignments yet.", color=ft.Colors.GREY)]),
            ],
        )

    def build_assignment_new_view():
        classes = fetch_classes()
        if not classes:
            return ft.View(
                route="/assignments/new",
                appbar=ft.AppBar(title=ft.Text("New Assignment")),
                controls=[
                    ft.Text(
                        "No classes have been set up yet. Ask the church office to add one.",
                        color=ft.Colors.GREY,
                    )
                ],
            )

        my_class = fetch_class_for_teacher(user["id"])
        default_class_id = my_class["class_id"] if my_class else classes[0]["class_id"]

        class_dropdown = ft.Dropdown(
            label="Class",
            value=str(default_class_id),
            options=[ft.DropdownOption(key=str(c["class_id"]), text=c["name"]) for c in classes],
        )
        title_field = ft.TextField(label="Title")
        description_field = ft.TextField(label="Description", multiline=True, min_lines=4)
        category_field = ft.TextField(label="Category")
        status_text = ft.Text("", color=ft.Colors.RED)

        async def submit(e):
            if not class_dropdown.value:
                status_text.value = "Please select a class."
                page.update()
                return
            if not title_field.value:
                status_text.value = "Please give the assignment a title."
                page.update()
                return
            try:
                insert_assignment(
                    title_field.value.strip(),
                    (description_field.value or "").strip() or None,
                    int(class_dropdown.value),
                    user["id"],
                    (category_field.value or "").strip() or None,
                )
            except Exception as ex:
                status_text.value = f"Error: {ex}"
                page.update()
                return
            await page.push_route("/assignments")

        return ft.View(
            route="/assignments/new",
            appbar=ft.AppBar(title=ft.Text("New Assignment")),
            controls=[
                ft.Container(
                    content=ft.Column(
                        [
                            class_dropdown,
                            title_field,
                            description_field,
                            category_field,
                            ft.FilledButton("Create", on_click=submit),
                            status_text,
                        ],
                        spacing=14,
                    ),
                    padding=16,
                )
            ],
        )

    def open_assignment_detail(a):
        def handler(e):
            complete_checkbox = ft.Checkbox(
                label="Complete", value=a.get("assignment_response_by") is not None
            )
            status_text = ft.Text("", color=ft.Colors.RED)

            def cancel(e2):
                page.pop_dialog()

            def submit_click(e2):
                if complete_checkbox.value:
                    try:
                        mark_assignment_response_complete(a["assignment_post_response_id"], user["id"])
                    except Exception as ex:
                        status_text.value = f"Error: {ex}"
                        page.update()
                        return
                page.pop_dialog()
                route_change(page.route)

            page.show_dialog(
                ft.AlertDialog(
                    modal=True,
                    title=ft.Text(a["assignment_title"]),
                    content=ft.Column(
                        [
                            ft.Text(
                                f"{a.get('student_name') or 'Unknown student'} · "
                                f"{a.get('class_name') or 'Unknown class'}"
                            ),
                            ft.Text(f"{a.get('category') or 'No category'} · {format_date(a['created_time'])}"),
                            ft.Divider(),
                            ft.Text(a.get("assignment_description") or "No description provided."),
                            ft.Divider(),
                            complete_checkbox,
                            status_text,
                        ],
                        tight=True,
                        scroll=ft.ScrollMode.AUTO,
                    ),
                    actions=[
                        ft.TextButton("Cancel", on_click=cancel),
                        ft.FilledButton("Submit", on_click=submit_click),
                    ],
                )
            )

        return handler

    def build_my_assignments_view():
        assignments = fetch_my_assignments(user["id"])
        tiles = [
            ft.ListTile(
                leading=ft.Icon(ft.Icons.ASSIGNMENT),
                title=ft.Text(
                    f"{a.get('student_name') or 'Unknown student'} · "
                    f"{a['assignment_title']} · {format_date(a['created_time'])}"
                ),
                subtitle=ft.Text(
                    f"{a.get('class_name') or 'Unknown class'} · {a.get('category') or 'No category'}"
                ),
                on_click=open_assignment_detail(a),
            )
            for a in assignments
        ]

        return ft.View(
            route="/my-assignments",
            appbar=ft.AppBar(title=ft.Text("Sunday School Parent")),
            controls=tiles or [ft.Text("No assignments yet.", color=ft.Colors.GREY)],
        )

    def build_home_view():
        if user["is_guest"]:
            welcome_text = "Welcome, Guest!"
        elif user["role"]:
            welcome_text = f"Welcome, {user['first_name']}, {user['role']}!"
        else:
            welcome_text = f"Welcome, {user['first_name']}!"

        header = ft.Column(
            [
                ft.Icon(ft.Icons.CHURCH, size=64, color=ft.Colors.PRIMARY),
                ft.Text(CHURCH_NAME, size=26, weight=ft.FontWeight.BOLD, text_align=ft.TextAlign.CENTER),
                ft.Text(f"{welcome_text} 🙏", size=16, color=ft.Colors.GREY),
            ],
            horizontal_alignment=ft.CrossAxisAlignment.CENTER,
            spacing=6,
        )

        menu_items = [
            ("Announcements", ft.Icons.CAMPAIGN, "/announcements"),
            ("Events", ft.Icons.EVENT, "/events"),
            ("Songs", ft.Icons.MUSIC_NOTE, "/songs"),
        ]
        if has_feature(user["role"], "assign_homework"):
            menu_items.append(("Sunday School Teacher", ft.Icons.SCHOOL, "/assignments"))
        if not user["is_guest"] and fetch_my_assignments(user["id"]):
            menu_items.append(("Sunday School Parent", ft.Icons.CHILD_CARE, "/my-assignments"))

        menu = ft.Column(
            [
                ft.Card(
                    content=ft.ListTile(
                        leading=ft.Icon(icon, color=ft.Colors.PRIMARY),
                        title=ft.Text(label, size=18),
                        trailing=ft.Icon(ft.Icons.CHEVRON_RIGHT),
                        on_click=go_to(route),
                    )
                )
                for label, icon, route in menu_items
            ],
            spacing=10,
        )

        return ft.View(
            route="/",
            appbar=ft.AppBar(
                title=ft.Text(CHURCH_NAME),
                actions=[ft.IconButton(ft.Icons.LOGOUT, tooltip="Log out", on_click=logout_click)],
            ),
            controls=[
                ft.Container(content=header, padding=ft.Padding.symmetric(vertical=30)),
                ft.Container(content=menu, padding=ft.Padding.symmetric(horizontal=16)),
            ],
        )

    def route_change(route):
        page.views.clear()

        if not is_logged_in():
            page.views.append(build_login_view())
            page.update()
            return

        page.views.append(build_home_view())

        r = page.route
        if r == "/announcements":
            page.views.append(build_list_view("/announcements", "Announcements", fetch_announcements(), "announcements"))
        elif r == "/announcements/new" and has_feature(user["role"], "edit_announcements"):
            page.views.append(build_announcement_form_view())
        elif r.startswith("/announcements/") and r.endswith("/edit") and has_feature(user["role"], "edit_announcements"):
            item = fetch_by_id("announcements", "announcement_id", r.split("/")[-2])
            if item:
                page.views.append(build_announcement_form_view(item))
        elif r.startswith("/announcements/"):
            item = fetch_by_id("announcements", "announcement_id", r.split("/")[-1])
            if item:
                page.views.append(build_detail_view(r, item, "announcements"))
        elif r == "/events":
            page.views.append(build_list_view("/events", "Events", fetch_events(), "events"))
        elif r == "/events/new" and has_feature(user["role"], "edit_events"):
            page.views.append(build_event_form_view())
        elif r.startswith("/events/") and r.endswith("/edit") and has_feature(user["role"], "edit_events"):
            item = fetch_by_id("events", "event_id", r.split("/")[-2])
            if item:
                page.views.append(build_event_form_view(item))
        elif r.startswith("/events/"):
            item = fetch_by_id("events", "event_id", r.split("/")[-1])
            if item:
                page.views.append(build_detail_view(r, item, "events"))
        elif r == "/songs":
            page.views.append(build_songs_view())
        elif r.startswith("/songs/"):
            page.views.append(build_song_lyrics_view(r.split("/")[-1]))
        elif r == "/assignments" and has_feature(user["role"], "assign_homework"):
            page.views.append(build_assignments_view())
        elif r == "/assignments/new" and has_feature(user["role"], "assign_homework"):
            page.views.append(build_assignment_new_view())
        elif r == "/my-assignments" and not user["is_guest"]:
            page.views.append(build_my_assignments_view())

        page.update()

    async def view_pop(e: ft.ViewPopEvent):
        if e.view is not None:
            page.views.remove(e.view)
        top_view = page.views[-1]
        await page.push_route(top_view.route)

    page.on_route_change = route_change
    page.on_view_pop = view_pop
    route_change(page.route)


ft.run(main)
