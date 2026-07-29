# Один активный worktree в Vigit

## Цель

Vigit должен занимать один native Neovim tab независимо от количества Git
worktree. В каждый момент времени активен только один worktree. Переключение
закрывает editor-состояние предыдущего worktree, но не удаляет его с диска и не
затрагивает пользовательские tabs вне Vigit.

## Модель workspace

Vigit хранит один `workspace`:

```text
workspace
├── tab
├── root
├── session
├── mode: review | code
├── source_buffers
├── terminal
└── snapshots[root]
```

Native tab представляет worktree. Обычные файловые buffers, LSP, Telescope и
`nvim-tree` работают в нём без Vigit-specific mappings. Review представлен
служебными `nofile` buffers, показанными как полноэкранный overlay-layout поверх
обычного editor layout. Поэтому вход и выход из review не уничтожают splits,
buffer history и пользовательские plugin windows.

Vigit не создаёт отдельный source tab. Если команда запущена из пустого
стартового tab, он становится workspace tab. Если текущий tab содержит рабочие
файлы выбранного worktree, Vigit также использует его. Если текущий tab
относится к другому проекту, Vigit создаёт один новый tab и не меняет исходный.

## Review и редактирование

- `:Vigit` открывает или фокусирует review overlay активного worktree.
- `e` закрывает overlay и открывает выбранный файл в последнем обычном editor
  window этого же tab.
- Повторный `:Vigit` восстанавливает выбранное изменение, курсор, раскрытый
  context и scroll position.
- `q` в review скрывает overlay и возвращает code mode. Он не закрывает tab и
  не переопределяется в source buffers.
- Закрытие workspace tab уничтожает связанную Vigit session и отменяет её
  незавершённые reads.

Diff и changes sidebar остаются визуально такими же, как сейчас. Они
открываются отдельными float windows внутри workspace tab; comments, help и
worktree picker располагаются выше них по `zindex`.

## Переключение worktree

`W` в review или `:VigitWorktrees` в code mode открывает picker. Выбор строки
запускает транзакцию:

1. Канонизировать target root и убедиться, что worktree ещё существует.
2. Проверить ресурсы текущего workspace.
3. Сохранить только UI snapshot текущего root.
4. Скрыть review overlay и отменить незавершённые reads.
5. Закрыть tracked source buffers текущего workspace без `force`.
6. Уничтожить старую session, переиспользовав workspace tab.
7. Выполнить tab-local `tcd` в target root.
8. Создать session target root, загрузить Git state и открыть review.

На диске старый worktree, его branch и незакоммиченные Git-изменения остаются
без изменений. Picker показывает `ACTIVE` только для текущего root; состояния
нескольких `OPEN` больше нет.

Если target activation завершилась ошибкой после закрытия старой session,
Vigit пытается восстановить предыдущий root из snapshot. Если и восстановление
не удалось, workspace tab остаётся обычным editor tab, а typed error попадает в
diagnostics.

## Безопасность buffers и terminal

Vigit отслеживает только normal buffers, которые были открыты или посещены в
workspace tab и чей канонический путь находится внутри активного root. Buffers
из других tabs и путей не входят в `source_buffers`.

Переключение блокируется, если:

- хотя бы один tracked source buffer имеет `modified=true`;
- tracked source buffer одновременно показан в постороннем tab;
- внутри workspace работает terminal process;
- target worktree исчез или больше не разрешается в собственный root.

Сообщение перечисляет блокирующие файлы или активный terminal. Force-switch,
автосохранение и автоматическое завершение shell не поддерживаются. Пользователь
сначала сохраняет или закрывает ресурс обычными средствами Neovim.

После завершения terminal его buffer можно закрыть при следующем переключении.
`T` открывает terminal как split текущего workspace tab и передаёт ему
tab-local root.

## Состояние и границы ответственности

`Workspace` отвечает за единственный активный root, tab, code resources и
переходы между режимами. `Session` продолжает отвечать за status, diffs,
comments, reads и mutations одного root. `Layout` только монтирует и снимает
review overlay; он больше не создаёт и не закрывает native tabs.

Registry сохраняет не более одной live session. Snapshot содержит только
логические UI-данные: selected change, source anchor, expanded context и режим
списка. Buffer/window handles в snapshot не сохраняются. При возврате к root
snapshot применяется только к существующим изменениям; устаревшие ссылки
отбрасываются.

## Совместимость

- Source buffers остаются `buflisted=true`, поэтому NvChad tabufline и
  Telescope показывают только файлы активного workspace.
- `tcd` изолирует cwd для `nvim-tree`, Telescope, terminal и LSP root
  discovery.
- Vigit не добавляет mappings, winbar или autocmd непосредственно в source
  buffers.
- Стандартные `gt`, `gT`, jumplist, `gd`, `Ctrl-o` и `Ctrl-i` работают как в
  пользовательском Neovim config.
- Закрытие постороннего tab не влияет на Vigit. Закрытие workspace tab
  завершает только активный workspace.

## Проверка

Headless-сценарии должны подтвердить:

1. три выбранных worktree последовательно используют один workspace tab;
2. после `e` review overlay исчезает, а source buffer остаётся listed;
3. `:Vigit` возвращает review и логический cursor anchor;
4. modified source buffer блокирует switch без потери текста;
5. source buffer, показанный в постороннем tab, блокирует switch;
6. работающий terminal блокирует switch и не получает сигнал завершения;
7. buffers и tabs вне workspace не меняются;
8. успешный switch закрывает buffers старого root и меняет tab-local cwd;
9. ошибка activation восстанавливает предыдущий root либо оставляет безопасный
   обычный editor tab;
10. закрытие workspace tab отменяет reads и очищает единственную session;
11. demo с двумя worktree никогда не создаёт две одновременные Vigit sessions.

Перед ручной проверкой запускается `./scripts/test.sh`. Затем
`./scripts/demo.sh --user-config` проверяет `W → switch → e → :Vigit`,
`nvim-tree`, Telescope, LSP navigation и terminal blocker.

## Вне scope

- одновременные Vigit sessions нескольких worktree;
- сохранение workspace snapshots между перезапусками Neovim;
- управление tmux panes;
- force-switch с потерей modified buffers;
- автоматический `git worktree remove`;
- собственные замены пользовательским LSP, Telescope или file tree.
