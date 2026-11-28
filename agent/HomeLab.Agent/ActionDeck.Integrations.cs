namespace HomeLab.Agent;

public sealed partial class ActionDeck
{
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, string> _actionResults = new();

    private DeckItem Describe(DeckAction action)
    {
        var state = action.Kind is "task" or "server" ? _tasks.State(action.Id) : _actionResults.GetValueOrDefault(action.Id);
        var available = true;
        if (action.Kind is "app" or "project" or "shortcut" or "focus")
        {
            var shortcut = _config.Get().Shortcuts.FirstOrDefault(s => s.Id == action.Target);
            available = shortcut is not null; state = shortcut is null ? "Shortcut is missing" : ShortcutRunning(shortcut) ? "Running" : "Ready";
        }
        return new(action.Id, action.Label, action.Kind, state, available);
    }
}
