# Generic build for any Store microservice project (WebApi or WorkerService).
#
# The build context is the repository root (one level above Store/), not the
# individual service folder, so that the local ProjectReference fallback each
# .csproj declares for Nur.Store2026.*/Joseco.* packages (see the
# Exists('$(MSBuildThisFileDirectory)...') conditions) resolves against the
# real SharedKernel/Utils source instead of a published NuGet package -
# those packages are not published anywhere this build can reach.
#
# Required build args:
#   PROJECT_PATH  - csproj to publish, relative to the repo root
#                   e.g. Services/Identity/Identity.WebApi/Identity.WebApi.csproj
#   ASSEMBLY_NAME - published entry assembly, e.g. Identity.WebApi.dll

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS base
WORKDIR /app

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
ARG PROJECT_PATH
WORKDIR /src
COPY . .
RUN dotnet restore "${PROJECT_PATH}"
RUN dotnet publish "${PROJECT_PATH}" -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
ARG ASSEMBLY_NAME
ENV ASSEMBLY_NAME=${ASSEMBLY_NAME}
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["sh", "-c", "exec dotnet \"$ASSEMBLY_NAME\""]
