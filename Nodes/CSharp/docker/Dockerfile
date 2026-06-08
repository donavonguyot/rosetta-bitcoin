# syntax=docker/dockerfile:1.7
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /workspace
COPY src/CsBitNode/CsBitNode.csproj src/CsBitNode/CsBitNode.csproj
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet restore src/CsBitNode/CsBitNode.csproj
COPY src src
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet publish src/CsBitNode/CsBitNode.csproj --no-restore -c Release -o /out

FROM mcr.microsoft.com/dotnet/runtime:8.0
WORKDIR /app
COPY --from=build /out ./
ENTRYPOINT ["dotnet", "/app/csbitnode.dll"]
