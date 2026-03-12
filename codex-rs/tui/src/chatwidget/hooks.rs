use std::collections::HashSet;
use std::path::PathBuf;

use super::ChatWidget;
use crate::app_event::AppEvent;
use crate::bottom_pane::SelectionItem;
use crate::bottom_pane::SelectionViewParams;
use crate::bottom_pane::custom_prompt_view::CustomPromptView;
use crate::bottom_pane::popup_consts::standard_popup_hint_line;
use crate::hooks_config::DEFAULT_HOOK_EVENT_KEYS;
use crate::hooks_config::HookId;
use crate::hooks_config::HookListEntry;
use crate::hooks_config::HookMutation;
use codex_app_server_protocol::ConfigLayerSource;
use codex_core::config_loader::ConfigLayerStackOrdering;
use ratatui::style::Stylize;
use ratatui::text::Line;

const CONFIG_TOML_FILE: &str = "config.toml";

const HOOKS_CONFIG_SEED: &str = r#"# Hooks
#
# See docs/hooks.md for the full hook reference and examples.
#
[hooks]
"#;

impl ChatWidget {
    pub(crate) fn open_hooks_menu(&mut self) {
        let mut items = Vec::new();

        let user_config_path = self.config.codex_home.join(CONFIG_TOML_FILE);
        items.push(SelectionItem {
            name: "全局钩子（用户）".to_string(),
            description: Some(user_config_path.display().to_string()),
            actions: vec![Box::new({
                let path = user_config_path.clone();
                move |tx| {
                    tx.send(AppEvent::OpenHooksManager {
                        scope_label: "全局钩子（用户）".to_string(),
                        path: path.clone(),
                        seed: HOOKS_CONFIG_SEED.to_string(),
                        disabled_reason: None,
                    });
                }
            })],
            dismiss_on_select: true,
            ..Default::default()
        });

        let mut seen_project_paths = HashSet::new();
        let mut has_project_layer = false;
        for layer in self
            .config
            .config_layer_stack
            .get_layers(ConfigLayerStackOrdering::HighestPrecedenceFirst, true)
        {
            let ConfigLayerSource::Project { dot_codex_folder } = &layer.name else {
                continue;
            };
            has_project_layer = true;

            let config_path = dot_codex_folder.as_path().join(CONFIG_TOML_FILE);
            if !seen_project_paths.insert(config_path.clone()) {
                continue;
            }

            let project_dir = dot_codex_folder
                .as_path()
                .parent()
                .unwrap_or(dot_codex_folder.as_path());
            let project_dir_display = project_dir.display().to_string();
            let config_path_display = config_path.display().to_string();
            let selected_description = layer
                .disabled_reason
                .as_ref()
                .map(|reason| format!("{config_path_display}\n\n{reason}"))
                .unwrap_or_else(|| config_path_display.clone());

            items.push(SelectionItem {
                name: format!("项目钩子（{project_dir_display}）"),
                description: Some(config_path_display),
                selected_description: Some(selected_description),
                actions: vec![Box::new({
                    let path = config_path.clone();
                    let scope_label = format!("项目钩子（{project_dir_display}）");
                    let disabled_reason = layer.disabled_reason.clone();
                    move |tx| {
                        tx.send(AppEvent::OpenHooksManager {
                            scope_label: scope_label.clone(),
                            path: path.clone(),
                            seed: HOOKS_CONFIG_SEED.to_string(),
                            disabled_reason: disabled_reason.clone(),
                        });
                    }
                })],
                dismiss_on_select: true,
                ..Default::default()
            });
        }

        if !has_project_layer {
            let project_root = codex_core::git_info::get_git_repo_root(self.config.cwd.as_path())
                .unwrap_or_else(|| self.config.cwd.clone());
            let config_path = project_root.join(".codex").join(CONFIG_TOML_FILE);
            let scope_label = format!("项目钩子（{}）", project_root.display());
            items.push(SelectionItem {
                name: scope_label.clone(),
                description: Some(config_path.display().to_string()),
                actions: vec![Box::new({
                    let path = config_path.clone();
                    move |tx| {
                        tx.send(AppEvent::OpenHooksManager {
                            scope_label: scope_label.clone(),
                            path: path.clone(),
                            seed: HOOKS_CONFIG_SEED.to_string(),
                            disabled_reason: None,
                        });
                    }
                })],
                dismiss_on_select: true,
                ..Default::default()
            });
        }

        self.bottom_pane.show_selection_view(SelectionViewParams {
            title: Some("钩子".to_string()),
            subtitle: Some("选择要管理的 config.toml 层。".to_string()),
            footer_hint: Some(standard_popup_hint_line()),
            items,
            ..Default::default()
        });
    }

    pub(crate) fn open_hooks_manager_view(
        &mut self,
        scope_label: String,
        path: PathBuf,
        seed: String,
        disabled_reason: Option<String>,
        entries: Vec<HookListEntry>,
    ) {
        let mut items = Vec::new();

        items.push(SelectionItem {
            name: "添加钩子".to_string(),
            description: Some("创建新的钩子条目。".to_string()),
            actions: vec![Box::new({
                let scope_label = scope_label.clone();
                let path = path.clone();
                let seed = seed.clone();
                let disabled_reason = disabled_reason.clone();
                move |tx| {
                    tx.send(AppEvent::OpenHooksAddEventPicker {
                        scope_label: scope_label.clone(),
                        path: path.clone(),
                        seed: seed.clone(),
                        disabled_reason: disabled_reason.clone(),
                    });
                }
            })],
            dismiss_on_select: true,
            ..Default::default()
        });

        items.push(SelectionItem {
            name: "编辑原始 config.toml".to_string(),
            description: Some("编辑整个文件（高级）。".to_string()),
            actions: vec![Box::new({
                let scope_label = scope_label.clone();
                let path = path.clone();
                let seed = seed.clone();
                let disabled_reason = disabled_reason.clone();
                move |tx| {
                    tx.send(AppEvent::OpenHooksRawEditor {
                        scope_label: scope_label.clone(),
                        path: path.clone(),
                        seed: seed.clone(),
                        disabled_reason: disabled_reason.clone(),
                    });
                }
            })],
            dismiss_on_select: true,
            ..Default::default()
        });

        for entry in entries {
            let title = entry.title.clone();
            items.push(SelectionItem {
                name: entry.title,
                description: entry.description,
                selected_description: entry.selected_description,
                search_value: Some(entry.search_value),
                actions: vec![Box::new({
                    let scope_label = scope_label.clone();
                    let path = path.clone();
                    let seed = seed.clone();
                    let disabled_reason = disabled_reason.clone();
                    let id = entry.id.clone();
                    let title = title.clone();
                    move |tx| {
                        tx.send(AppEvent::OpenHooksEntryActions {
                            scope_label: scope_label.clone(),
                            path: path.clone(),
                            seed: seed.clone(),
                            disabled_reason: disabled_reason.clone(),
                            id: id.clone(),
                            title: title.clone(),
                        });
                    }
                })],
                dismiss_on_select: true,
                ..Default::default()
            });
        }

        let footer_note = disabled_reason
            .as_deref()
            .map(|reason| Line::from(format!("已禁用：{reason}").dim()));

        self.bottom_pane.show_selection_view(SelectionViewParams {
            title: Some(scope_label),
            subtitle: Some(path.display().to_string()),
            footer_note,
            footer_hint: Some(standard_popup_hint_line()),
            is_searchable: true,
            search_placeholder: Some("输入以搜索钩子".to_string()),
            items,
            ..Default::default()
        });
    }

    pub(crate) fn open_hooks_add_event_picker(
        &mut self,
        scope_label: String,
        path: PathBuf,
        seed: String,
        disabled_reason: Option<String>,
    ) {
        let mut items = Vec::new();
        for event in DEFAULT_HOOK_EVENT_KEYS {
            items.push(SelectionItem {
                name: (*event).to_string(),
                description: Some("按 Enter 为此事件添加钩子。".to_string()),
                actions: vec![Box::new({
                    let scope_label = scope_label.clone();
                    let path = path.clone();
                    let seed = seed.clone();
                    let disabled_reason = disabled_reason.clone();
                    let event = (*event).to_string();
                    move |tx| {
                        tx.send(AppEvent::OpenHooksAddPrompt {
                            scope_label: scope_label.clone(),
                            path: path.clone(),
                            seed: seed.clone(),
                            disabled_reason: disabled_reason.clone(),
                            event: event.clone(),
                        });
                    }
                })],
                dismiss_on_select: true,
                ..Default::default()
            });
        }

        items.push(SelectionItem {
            name: "返回".to_string(),
            actions: vec![Box::new({
                let scope_label = scope_label.clone();
                let path = path.clone();
                let seed = seed.clone();
                let disabled_reason = disabled_reason.clone();
                move |tx| {
                    tx.send(AppEvent::OpenHooksManager {
                        scope_label: scope_label.clone(),
                        path: path.clone(),
                        seed: seed.clone(),
                        disabled_reason: disabled_reason.clone(),
                    });
                }
            })],
            dismiss_on_select: true,
            ..Default::default()
        });

        self.bottom_pane.show_selection_view(SelectionViewParams {
            title: Some("添加钩子".to_string()),
            subtitle: Some(scope_label),
            footer_hint: Some(standard_popup_hint_line()),
            items,
            ..Default::default()
        });
    }

    pub(crate) fn open_hooks_entry_actions(
        &mut self,
        scope_label: String,
        path: PathBuf,
        seed: String,
        disabled_reason: Option<String>,
        id: HookId,
        title: String,
    ) {
        let mut items = Vec::new();

        items.push(SelectionItem {
            name: "编辑".to_string(),
            actions: vec![Box::new({
                let scope_label = scope_label.clone();
                let path = path.clone();
                let seed = seed.clone();
                let disabled_reason = disabled_reason.clone();
                let id = id.clone();
                let title = title.clone();
                move |tx| {
                    tx.send(AppEvent::OpenHooksEditPrompt {
                        scope_label: scope_label.clone(),
                        path: path.clone(),
                        seed: seed.clone(),
                        disabled_reason: disabled_reason.clone(),
                        id: id.clone(),
                        title: title.clone(),
                    });
                }
            })],
            dismiss_on_select: true,
            ..Default::default()
        });

        items.push(SelectionItem {
            name: "删除".to_string(),
            actions: vec![Box::new({
                let scope_label = scope_label.clone();
                let path = path.clone();
                let seed = seed.clone();
                let disabled_reason = disabled_reason.clone();
                let id = id.clone();
                let title = title.clone();
                move |tx| {
                    tx.send(AppEvent::OpenHooksDeleteConfirm {
                        scope_label: scope_label.clone(),
                        path: path.clone(),
                        seed: seed.clone(),
                        disabled_reason: disabled_reason.clone(),
                        id: id.clone(),
                        title: title.clone(),
                    });
                }
            })],
            dismiss_on_select: true,
            ..Default::default()
        });

        items.push(SelectionItem {
            name: "返回".to_string(),
            actions: vec![Box::new({
                let scope_label = scope_label.clone();
                let path = path.clone();
                let seed = seed.clone();
                let disabled_reason = disabled_reason.clone();
                move |tx| {
                    tx.send(AppEvent::OpenHooksManager {
                        scope_label: scope_label.clone(),
                        path: path.clone(),
                        seed: seed.clone(),
                        disabled_reason: disabled_reason.clone(),
                    });
                }
            })],
            dismiss_on_select: true,
            ..Default::default()
        });

        self.bottom_pane.show_selection_view(SelectionViewParams {
            title: Some(title),
            subtitle: Some(scope_label),
            footer_hint: Some(standard_popup_hint_line()),
            items,
            ..Default::default()
        });
    }

    pub(crate) fn open_hooks_editor(
        &mut self,
        title: String,
        scope_label: String,
        path: PathBuf,
        seed: String,
        disabled_reason: Option<String>,
        initial_text: String,
        mutation: HookMutation,
    ) {
        let tx = self.app_event_tx.clone();
        let context = format!("{scope_label} — {}", path.display());
        let view = CustomPromptView::new(
            title,
            "编辑 TOML 后按 Enter".to_string(),
            Some(context),
            Some(initial_text),
            Box::new(move |text: String| {
                tx.send(AppEvent::ApplyHooksMutation {
                    scope_label: scope_label.clone(),
                    path: path.clone(),
                    seed: seed.clone(),
                    disabled_reason: disabled_reason.clone(),
                    mutation: match &mutation {
                        HookMutation::Add { event, .. } => HookMutation::Add {
                            event: event.clone(),
                            snippet: text.clone(),
                        },
                        HookMutation::Replace { id, .. } => HookMutation::Replace {
                            id: id.clone(),
                            snippet: text.clone(),
                        },
                        HookMutation::Delete { id } => HookMutation::Delete { id: id.clone() },
                        HookMutation::ReplaceRaw { .. } => HookMutation::ReplaceRaw {
                            contents: text.clone(),
                        },
                    },
                });
            }),
        );
        self.bottom_pane.show_view(Box::new(view));
    }

    pub(crate) fn open_hooks_delete_confirm(
        &mut self,
        scope_label: String,
        path: PathBuf,
        seed: String,
        disabled_reason: Option<String>,
        id: HookId,
        title: String,
    ) {
        let mut items = Vec::new();

        items.push(SelectionItem {
            name: "删除钩子".to_string(),
            description: Some("此操作不可撤销。".to_string()),
            actions: vec![Box::new({
                let scope_label = scope_label.clone();
                let path = path.clone();
                let seed = seed.clone();
                let disabled_reason = disabled_reason.clone();
                let id = id.clone();
                move |tx| {
                    tx.send(AppEvent::ApplyHooksMutation {
                        scope_label: scope_label.clone(),
                        path: path.clone(),
                        seed: seed.clone(),
                        disabled_reason: disabled_reason.clone(),
                        mutation: HookMutation::Delete { id: id.clone() },
                    });
                }
            })],
            dismiss_on_select: true,
            ..Default::default()
        });

        items.push(SelectionItem {
            name: "取消".to_string(),
            actions: vec![Box::new({
                let scope_label = scope_label.clone();
                let path = path.clone();
                let seed = seed.clone();
                let disabled_reason = disabled_reason.clone();
                let id = id.clone();
                let title = title.clone();
                move |tx| {
                    tx.send(AppEvent::OpenHooksEntryActions {
                        scope_label: scope_label.clone(),
                        path: path.clone(),
                        seed: seed.clone(),
                        disabled_reason: disabled_reason.clone(),
                        id: id.clone(),
                        title: title.clone(),
                    });
                }
            })],
            dismiss_on_select: true,
            ..Default::default()
        });

        self.bottom_pane.show_selection_view(SelectionViewParams {
            title: Some("确认删除".to_string()),
            subtitle: Some(title),
            footer_hint: Some(standard_popup_hint_line()),
            items,
            ..Default::default()
        });
    }
}
