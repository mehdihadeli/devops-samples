

using Microsoft.EntityFrameworkCore;

namespace DotnetK8sSetup.Features.Todos;

public static class TodoEndpoints
{
    public static IEndpointRouteBuilder MapTodoEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/todos").WithTags("Todos");

        group.MapGet("/", async (TodoDbContext db) =>
        {
            var todos = await db.Todos.AsNoTracking().ToListAsync();
            return Results.Ok(todos.Select(TodoResponse.FromEntity));
        })
        .WithName("GetAllTodos")
        .WithSummary("Get all todos");

        group.MapGet("/{id:guid}", async (Guid id, TodoDbContext db) =>
        {
            var todo = await db.Todos.FindAsync(id);
            return todo is null
                ? Results.NotFound()
                : Results.Ok(TodoResponse.FromEntity(todo));
        })
        .WithName("GetTodoById")
        .WithSummary("Get a todo by id");

        group.MapPost("/", async (CreateTodoRequest request, TodoDbContext db) =>
        {
            if (string.IsNullOrWhiteSpace(request.Title))
                return Results.ValidationProblem(new Dictionary<string, string[]>
                {
                    { nameof(request.Title), ["Title is required."] }
                });

            var todo = new TodoItem { Title = request.Title.Trim() };
            db.Todos.Add(todo);
            await db.SaveChangesAsync();

            return Results.Created($"/todos/{todo.Id}", TodoResponse.FromEntity(todo));
        })
        .WithName("CreateTodo")
        .WithSummary("Create a new todo");

        group.MapPut("/{id:guid}", async (Guid id, UpdateTodoRequest request, TodoDbContext db) =>
        {
            var todo = await db.Todos.FindAsync(id);
            if (todo is null) return Results.NotFound();

            todo.Title = request.Title.Trim();
            todo.IsComplete = request.IsComplete;
            await db.SaveChangesAsync();

            return Results.Ok(TodoResponse.FromEntity(todo));
        })
        .WithName("UpdateTodo")
        .WithSummary("Update a todo");

        group.MapDelete("/{id:guid}", async (Guid id, TodoDbContext db) =>
        {
            var todo = await db.Todos.FindAsync(id);
            if (todo is null) return Results.NotFound();

            db.Todos.Remove(todo);
            await db.SaveChangesAsync();

            return Results.NoContent();
        })
        .WithName("DeleteTodo")
        .WithSummary("Delete a todo");

        return app;
    }
}

