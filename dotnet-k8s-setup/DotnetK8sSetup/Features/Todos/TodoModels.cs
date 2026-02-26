namespace DotnetK8sSetup.Features.Todos;

public record CreateTodoRequest(string Title);

public record UpdateTodoRequest(string Title, bool IsComplete);

public record TodoResponse(Guid Id, string Title, bool IsComplete, DateTimeOffset CreatedAt)
{
    public static TodoResponse FromEntity(TodoItem item) =>
        new(item.Id, item.Title, item.IsComplete, item.CreatedAt);
}

