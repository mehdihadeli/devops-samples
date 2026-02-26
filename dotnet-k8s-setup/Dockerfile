# Stage 1: Build
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY ["DotnetK8sSetup/DotnetK8sSetup.csproj", "DotnetK8sSetup/"]
RUN dotnet restore "DotnetK8sSetup/DotnetK8sSetup.csproj"

COPY . .
WORKDIR "/src/DotnetK8sSetup"
RUN dotnet publish "DotnetK8sSetup.csproj" -c Release -o /app/publish --no-restore

# Stage 2: Runtime
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app

COPY --from=build /app/publish .

# ASP.NET Core listens on 8080 by default (non-root)
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

ENTRYPOINT ["dotnet", "DotnetK8sSetup.dll"]

